#!/usr/bin/env bash
# backup-now.sh
# Purpose: Trigger a backup immediately instead of waiting for the schedule.
# depends_on: [k8s/data/backup/mongo-cronjob.yaml, k8s/data/backup/redis-cronjob.yaml]
#
# usage: backup-now.sh [mongo|redis|all]      (default: mongo)
#
# Run this before anything risky - a migration, a bulk delete, a Mongo version
# bump. Nightly backups mean an RPO of up to 24h; this closes that window when
# you know you are about to do something you might regret.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl

WHICH="${1:-mongo}"

trigger() {
  local cronjob="$1"
  local job
  job="${cronjob}-manual-$(date +%s)"

  kubectl -n data get cronjob "$cronjob" >/dev/null 2>&1 \
    || die "cronjob/$cronjob not found - run 'make backup' first"

  log "Triggering $cronjob..."
  kubectl -n data create job "$job" --from="cronjob/$cronjob" >/dev/null

  for _ in $(seq 1 60); do
    kubectl -n data get pod -l "job-name=${job}" 2>/dev/null | grep -q . && break
    sleep 1
  done

  # -f follows the upload container; the dump runs as an initContainer, so its
  # output appears once that completes.
  kubectl -n data logs -f "job/${job}" 2>/dev/null || true

  if kubectl -n data wait --for=condition=complete "job/${job}" --timeout=900s >/dev/null 2>&1; then
    ok "$cronjob completed"
    kubectl -n data delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
    return 0
  fi

  log "--- initContainer (dump) log ---"
  kubectl -n data logs "job/${job}" -c dump --tail=30 2>/dev/null \
    || kubectl -n data logs "job/${job}" -c snapshot --tail=30 2>/dev/null || true
  log "--- upload log ---"
  kubectl -n data logs "job/${job}" -c upload --tail=30 2>/dev/null || true
  kubectl -n data delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
  die "$cronjob failed - see the logs above. The staging copy is kept on a
  failed upload, so nothing was lost; inspect it with:
    kubectl -n data run staging-check --rm -it --restart=Never --image=busybox \\
      --overrides='{\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":\"busybox\",
      \"command\":[\"ls\",\"-la\",\"/staging\"],\"volumeMounts\":[{\"name\":\"s\",
      \"mountPath\":\"/staging\"}]}],\"volumes\":[{\"name\":\"s\",
      \"persistentVolumeClaim\":{\"claimName\":\"backup-staging\"}}]}}'"
}

case "$WHICH" in
  mongo) trigger mongo-backup ;;
  redis) trigger redis-backup ;;
  all)
    # Sequential, never parallel: both jobs mount the same RWO staging PVC.
    trigger mongo-backup
    trigger redis-backup
    ;;
  *) die "usage: backup-now.sh [mongo|redis|all]" ;;
esac
