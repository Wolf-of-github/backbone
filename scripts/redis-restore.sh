#!/usr/bin/env bash
# redis-restore.sh
# Purpose: List and inspect Redis backups from external S3.
# depends_on: [k8s/data/backup/redis-cronjob.yaml, scripts/lib.sh]
#
# usage:
#   redis-restore.sh list
#   redis-restore.sh inspect <key>          load into a THROWAWAY Redis and report
#   redis-restore.sh restore <key> --overwrite-production --confirm
#
# READ THIS BEFORE RESTORING REDIS
# This Redis holds refresh tokens (Phase 3) and the BullMQ queue (Phase 4).
# Restoring it therefore:
#   - REVIVES refresh tokens that were deliberately revoked at logout, letting
#     old sessions mint new access tokens again;
#   - REPLAYS queued jobs that may already have run, so anything non-idempotent
#     (charging a card, sending mail) happens a second time.
# MongoDB is the authoritative store; Redis is closer to durable cache. This
# backup exists for total-loss recovery, not routine rollback. `inspect` is the
# command you almost always want.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl

kubectl -n data get secret backup-s3-credentials >/dev/null 2>&1 \
  || die "secret/backup-s3-credentials missing - run 'make backup' first"

COMMAND="${1:-list}"
shift || true

s3_env() {
  cat <<'ENVYAML'
        envFrom:
        - secretRef:
            name: backup-s3-credentials
        env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: backup-s3-credentials, key: access-key } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: backup-s3-credentials, key: secret-key } }
        - name: AWS_DEFAULT_REGION
          valueFrom: { secretKeyRef: { name: backup-s3-credentials, key: region } }
        - name: REDIS_PASSWORD
          valueFrom: { secretKeyRef: { name: redis-password, key: password } }
ENVYAML
}

run_job() {
  local job="$1" fetch="$2" main="$3"
  kubectl -n data apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - name: fetch
        image: amazon/aws-cli:2.17.0
        command: ["/bin/bash","-c"]
        args:
        - |
${fetch}
$(s3_env)
        volumeMounts:
        - { name: shared, mountPath: /shared }
      containers:
      - name: redis
        image: redis:7.2-alpine
        command: ["/bin/sh","-c"]
        args:
        - |
${main}
$(s3_env)
        volumeMounts:
        - { name: shared, mountPath: /shared }
      volumes:
      - { name: shared, emptyDir: {} }
YAML

  log "Job ${job} running..."
  for _ in $(seq 1 60); do
    kubectl -n data get pod -l "job-name=${job}" 2>/dev/null | grep -q . && break
    sleep 1
  done
  kubectl -n data logs -f "job/${job}" 2>/dev/null || true

  if kubectl -n data wait --for=condition=complete "job/${job}" --timeout=600s >/dev/null 2>&1; then
    kubectl -n data delete job "${job}" --ignore-not-found >/dev/null 2>&1 || true
    return 0
  fi
  kubectl -n data logs "job/${job}" --tail=30 2>/dev/null || true
  kubectl -n data delete job "${job}" --ignore-not-found >/dev/null 2>&1 || true
  return 1
}

case "$COMMAND" in
  list)
    log "Available Redis backups (newest first):"
    run_job "redis-list-$(date +%s)" \
      '          set -euo pipefail
          EP=""
          [ -n "${endpoint:-}" ] && EP="--endpoint-url ${endpoint}"
          aws $EP s3 ls "s3://${bucket}/${prefix}/redis/" --human-readable \
            | sort -r > /shared/output.txt' \
      '          cat /shared/output.txt' \
      || die "could not list backups - check the bucket and credentials"
    ;;

  inspect)
    KEY="${1:-}"
    [ -n "$KEY" ] || die "usage: redis-restore.sh inspect <key>"
    log "Loading '$KEY' into a throwaway Redis (production untouched)..."
    run_job "redis-inspect-$(date +%s)" \
      "          set -euo pipefail
          EP=\"\"
          [ -n \"\${endpoint:-}\" ] && EP=\"--endpoint-url \${endpoint}\"
          aws \$EP s3 cp \"s3://\${bucket}/\${prefix}/redis/${KEY}\" /shared/dump.rdb
          stat -c'%s bytes downloaded' /shared/dump.rdb" \
      '          set -eu
          redis-check-rdb /shared/dump.rdb || { echo "RDB is corrupt"; exit 1; }
          # Start a private Redis on the dump, query it, then discard it.
          cp /shared/dump.rdb /data/dump.rdb 2>/dev/null || mkdir -p /data && cp /shared/dump.rdb /data/dump.rdb
          redis-server --dir /data --dbfilename dump.rdb --port 6399 --daemonize yes
          sleep 3
          echo "--- contents ---"
          redis-cli -p 6399 DBSIZE
          echo "sample keys:"
          redis-cli -p 6399 --scan --count 20 | head -20
          redis-cli -p 6399 SHUTDOWN NOSAVE 2>/dev/null || true' \
      || die "inspect failed"
    ok "Inspection complete - nothing in production was touched"
    ;;

  restore)
    KEY="${1:-}"
    [ -n "$KEY" ] || die "usage: redis-restore.sh restore <key> --overwrite-production --confirm"
    shift
    OVERWRITE=false; CONFIRMED=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --overwrite-production) OVERWRITE=true; shift ;;
        --confirm)              CONFIRMED=true; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done

    { [ "$OVERWRITE" = true ] && [ "$CONFIRMED" = true ]; } || die \
"Restoring Redis requires --overwrite-production --confirm.

  There is no safe in-place Redis restore: unlike MongoDB there is no namespace
  to redirect into, so a restore replaces the live keyspace. That means:
    - refresh tokens revoked at logout become valid again
    - queued jobs that already ran are replayed

  To look at a backup's contents without touching production:
    ./scripts/redis-restore.sh inspect $KEY"

    log ""
    log "*** REPLACING THE LIVE REDIS KEYSPACE ***"
    log "Revoked sessions will be revived and completed jobs may re-run."
    log ""

    # Flush + repopulate over the wire. Editing the PVC directly would mean
    # stopping Redis, and the PVC is RWO and attached to the running pod.
    run_job "redis-restore-$(date +%s)" \
      "          set -euo pipefail
          EP=\"\"
          [ -n \"\${endpoint:-}\" ] && EP=\"--endpoint-url \${endpoint}\"
          aws \$EP s3 cp \"s3://\${bucket}/\${prefix}/redis/${KEY}\" /shared/dump.rdb" \
      '          set -eu
          redis-check-rdb /shared/dump.rdb || { echo "RDB is corrupt - aborting"; exit 1; }
          mkdir -p /data && cp /shared/dump.rdb /data/dump.rdb
          redis-server --dir /data --dbfilename dump.rdb --port 6399 --daemonize yes
          sleep 3
          SRC="redis-cli -p 6399"
          DST="redis-cli -h redis.data.svc -a $REDIS_PASSWORD --no-auth-warning"
          echo "source keys: $($SRC DBSIZE)"
          echo "flushing live keyspace"
          $DST FLUSHALL
          # MIGRATE moves keys with their TTLs intact - a plain GET/SET loop
          # would silently turn expiring tokens into permanent ones.
          $SRC --scan | while read -r k; do
            [ -n "$k" ] || continue
            $SRC MIGRATE redis.data.svc 6379 "$k" 0 5000 AUTH "$REDIS_PASSWORD" REPLACE >/dev/null 2>&1 || true
          done
          echo "restored keys: $($DST DBSIZE)"
          $SRC SHUTDOWN NOSAVE 2>/dev/null || true' \
      || die "restore failed"
    ok "Redis keyspace restored from $KEY"
    ;;

  *)
    die "usage: redis-restore.sh <list|inspect|restore>"
    ;;
esac
