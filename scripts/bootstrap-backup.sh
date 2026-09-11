#!/usr/bin/env bash
# bootstrap-backup.sh
# Purpose: Phase 6A - stand up the backup CronJobs, staging volume and PDBs.
# depends_on: [scripts/backup-secrets.sh, k8s/data/backup/**, k8s/base/pdb.yaml]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need envsubst

RENDER_DIR="$REPO_ROOT/.rendered/backup"
BACKUP_DIR="k8s/data/backup"

kubectl get ns data >/dev/null 2>&1 || die "namespace 'data' missing - run 'make base' first"

for sts in mongodb redis; do
  ready=$(kubectl -n data get statefulset "$sts" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "${ready:-0}" -ge 1 ] || die "statefulset/$sts is not Ready - Phase 1 must be healthy first"
done

: "${BACKUP_SCHEDULE_MONGO:=0 3 * * *}"
: "${BACKUP_SCHEDULE_REDIS:=0 4 * * *}"
: "${BACKUP_RETENTION_DAYS:=30}"
: "${BACKUP_STAGING_SIZE:=5Gi}"

mkdir -p "$RENDER_DIR"

# ---------------------------------------------------------------------------
# 1. Credentials
# ---------------------------------------------------------------------------
"$REPO_ROOT/scripts/backup-secrets.sh"

# ---------------------------------------------------------------------------
# 2. PREFLIGHT - prove the bucket and credentials work BEFORE creating
#    anything that depends on them.
#
#    Without this, a typo'd bucket name or a wrong key produces a perfectly
#    healthy-looking CronJob that fails silently at 03:00, and you discover it
#    when you need the backup. Ten seconds here buys that back.
# ---------------------------------------------------------------------------
log "Preflight: checking bucket access..."
PREFLIGHT_POD="backup-preflight-$$"
cleanup_preflight() {
  kubectl -n data delete pod "$PREFLIGHT_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup_preflight EXIT

if ! kubectl -n data run "$PREFLIGHT_POD" --rm -i --restart=Never --quiet \
  --image=amazon/aws-cli:2.17.0 \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "aws",
        "image": "amazon/aws-cli:2.17.0",
        "command": ["/bin/bash","-c"],
        "args": ["set -e; EP=\"\"; [ -n \"${endpoint:-}\" ] && EP=\"--endpoint-url ${endpoint}\"; aws $EP s3api head-bucket --bucket \"$bucket\" && echo PREFLIGHT_OK"],
        "envFrom": [{"secretRef": {"name": "backup-s3-credentials"}}],
        "env": [
          {"name":"AWS_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"backup-s3-credentials","key":"access-key"}}},
          {"name":"AWS_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"backup-s3-credentials","key":"secret-key"}}},
          {"name":"AWS_DEFAULT_REGION","valueFrom":{"secretKeyRef":{"name":"backup-s3-credentials","key":"region"}}}
        ]
      }]
    }
  }' 2>/dev/null | grep -q PREFLIGHT_OK; then
  die "cannot reach the backup bucket '${BACKUP_S3_BUCKET}'.

  Check in .env:
    BACKUP_S3_BUCKET      the bucket must ALREADY EXIST - this does not create it
    BACKUP_S3_ACCESS_KEY  / BACKUP_S3_SECRET_KEY
    BACKUP_S3_ENDPOINT    required for non-AWS providers (B2, R2, MinIO)
    BACKUP_S3_REGION      some providers reject a mismatched region

  After correcting .env, re-run 'make backup'."
fi
ok "bucket '${BACKUP_S3_BUCKET}' reachable"
cleanup_preflight
trap - EXIT

# ---------------------------------------------------------------------------
# 3. Staging volume, CronJobs, PDBs
# ---------------------------------------------------------------------------
export BACKUP_STAGING_SIZE BACKUP_SCHEDULE_MONGO BACKUP_SCHEDULE_REDIS BACKUP_RETENTION_DAYS

render_template "$BACKUP_DIR/staging-pvc.yaml" "$RENDER_DIR/staging-pvc.yaml" 'BACKUP_STAGING_SIZE'
kubectl apply -f "$RENDER_DIR/staging-pvc.yaml" >/dev/null
ok "staging PVC (${BACKUP_STAGING_SIZE})"

render_template "$BACKUP_DIR/mongo-cronjob.yaml" "$RENDER_DIR/mongo-cronjob.yaml" \
  'BACKUP_SCHEDULE_MONGO BACKUP_RETENTION_DAYS'
kubectl apply -f "$RENDER_DIR/mongo-cronjob.yaml" >/dev/null
ok "cronjob/mongo-backup (${BACKUP_SCHEDULE_MONGO})"

render_template "$BACKUP_DIR/redis-cronjob.yaml" "$RENDER_DIR/redis-cronjob.yaml" \
  'BACKUP_SCHEDULE_REDIS BACKUP_RETENTION_DAYS'
kubectl apply -f "$RENDER_DIR/redis-cronjob.yaml" >/dev/null
ok "cronjob/redis-backup (${BACKUP_SCHEDULE_REDIS})"

kubectl apply -f k8s/base/pdb.yaml >/dev/null
ok "PodDisruptionBudgets"

log ""
log "Next scheduled runs:"
kubectl -n data get cronjob mongo-backup redis-backup \
  -o custom-columns=NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST:.status.lastScheduleTime 2>/dev/null || true

log ""
log "Backups are only real once restored. Before trusting this:"
log "  ./scripts/backup-now.sh mongo          # take one now"
log "  ./scripts/mongo-restore.sh list        # confirm it landed"
log "  ./scripts/mongo-restore.sh restore <key> --target restore_check"
log ""
log "Retention: ${BACKUP_RETENTION_DAYS} days. RPO: up to 24h between scheduled runs."
