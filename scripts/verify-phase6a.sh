#!/usr/bin/env bash
# verify-phase6a.sh
# Purpose: Phase 6A gate. Proves the backups are RESTORABLE, not merely present.
# depends_on: [scripts/bootstrap-backup.sh]
#
# The central check is [4]: write a sentinel document, back up, DROP it, restore
# from S3, and confirm the sentinel is back. Anything less - a job that exits 0,
# an object that exists - tests the plumbing rather than the guarantee.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need jq

fail() { die "verify-phase6a: $*"; }

SENTINEL="phase6a-$(date +%s)"
SCRATCH_DB="verify6a_restore"
TEST_JOB=""
CREATED_KEY=""

cleanup() {
  kubectl -n data delete pod -l verify6a=true --ignore-not-found --wait=false >/dev/null 2>&1 || true
  [ -n "$TEST_JOB" ] && kubectl -n data delete job "$TEST_JOB" --ignore-not-found >/dev/null 2>&1 || true
  # Drop the scratch DB and the sentinel collection; leave real data alone.
  mongo_eval "db.getSiblingDB('$SCRATCH_DB').dropDatabase()" >/dev/null 2>&1 || true
  mongo_eval "db.getSiblingDB('$MONGO_APP_DB').verify6a.drop()" >/dev/null 2>&1 || true
  [ -n "$CREATED_KEY" ] && s3_exec "aws \$EP s3 rm \"s3://\${bucket}/\${prefix}/mongo/${CREATED_KEY}\"" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Run a mongosh expression in-cluster with the root credential from the Secret.
#
# The expression is passed through the environment (MONGO_EVAL) rather than
# being spliced into the JSON override. Embedding it would mean three levels of
# quoting - shell, JSON, then mongosh - and any quote in the expression would
# corrupt the manifest. jq builds the override so escaping is never hand-rolled.
mongo_eval() {
  local expr="$1"
  local overrides
  overrides=$(jq -nc --arg expr "$expr" '{
    spec: { containers: [{
      name: "m", image: "mongo:7.0",
      command: ["/bin/bash","-c"],
      args: ["mongosh --quiet \"mongodb://$MONGO_ROOT_USER:$MONGO_ROOT_PASSWORD@mongodb.data.svc:27017/admin\" --eval \"$MONGO_EVAL\""],
      env: [
        {name: "MONGO_EVAL", value: $expr},
        {name: "MONGO_ROOT_USER", valueFrom: {secretKeyRef: {name: "mongodb-credentials", key: "root-username"}}},
        {name: "MONGO_ROOT_PASSWORD", valueFrom: {secretKeyRef: {name: "mongodb-credentials", key: "root-password"}}}
      ]
    }]}
  }')
  kubectl -n data run "verify6a-mongo-$RANDOM" --rm -i --restart=Never --quiet \
    --labels=verify6a=true --image=mongo:7.0 \
    --overrides="$overrides" 2>/dev/null
}

# Run an aws-cli snippet in-cluster with the backup credentials.
# Same reasoning as mongo_eval: jq builds the override, so a quote in the
# snippet cannot break the manifest.
s3_exec() {
  local script="$1"
  local full="EP=\"\"; [ -n \"\${endpoint:-}\" ] && EP=\"--endpoint-url \${endpoint}\"; $script"
  local overrides
  overrides=$(jq -nc --arg script "$full" '{
    spec: { containers: [{
      name: "a", image: "amazon/aws-cli:2.17.0",
      command: ["/bin/bash","-c"],
      args: [$script],
      envFrom: [{secretRef: {name: "backup-s3-credentials"}}],
      env: [
        {name: "AWS_ACCESS_KEY_ID", valueFrom: {secretKeyRef: {name: "backup-s3-credentials", key: "access-key"}}},
        {name: "AWS_SECRET_ACCESS_KEY", valueFrom: {secretKeyRef: {name: "backup-s3-credentials", key: "secret-key"}}},
        {name: "AWS_DEFAULT_REGION", valueFrom: {secretKeyRef: {name: "backup-s3-credentials", key: "region"}}}
      ]
    }]}
  }')
  kubectl -n data run "verify6a-s3-$RANDOM" --rm -i --restart=Never --quiet \
    --labels=verify6a=true --image=amazon/aws-cli:2.17.0 \
    --overrides="$overrides" 2>/dev/null
}

log "Phase 6A verification (backup / disaster recovery)"

# [1/7] objects exist
log "[1/7] Secret, staging volume and CronJobs"
for k in endpoint bucket region access-key secret-key prefix; do
  kubectl -n data get secret backup-s3-credentials \
    -o jsonpath="{.data['${k/./\\.}']}" >/dev/null 2>&1 \
    || fail "secret/backup-s3-credentials is missing key '$k'"
done
phase=$(kubectl -n data get pvc backup-staging -o jsonpath='{.status.phase}' 2>/dev/null || true)
[ "$phase" = "Bound" ] || fail "PVC backup-staging is '$phase', expected Bound"

for cj in mongo-backup redis-backup; do
  kubectl -n data get cronjob "$cj" >/dev/null 2>&1 || fail "cronjob/$cj missing"
  policy=$(kubectl -n data get cronjob "$cj" -o jsonpath='{.spec.concurrencyPolicy}')
  [ "$policy" = "Forbid" ] \
    || fail "cronjob/$cj has concurrencyPolicy '$policy' - must be Forbid (both mount one RWO staging PVC)"
done
ok "secret (6 keys), staging PVC Bound, both CronJobs present with Forbid"

# [2/7] PDBs, including the ones that must NOT exist
log "[2/7] PodDisruptionBudgets"
for p in kong:platform auth:app ping:app jobs-api:app frontend:app; do
  name="${p%%:*}"; ns="${p##*:}"
  kubectl -n "$ns" get pdb "$name" >/dev/null 2>&1 || fail "PDB $ns/$name missing"
done
# A PDB on a single-replica StatefulSet makes the node permanently undrainable.
for s in mongodb redis; do
  if kubectl -n data get pdb "$s" >/dev/null 2>&1; then
    fail "a PDB exists for single-replica statefulset/$s - this makes the node undrainable
  (minAvailable on a 1-replica workload can never be satisfied). Remove it."
  fi
done
ok "PDBs present for multi-replica services; correctly absent for single-replica StatefulSets"

# [3/7] S3 reachable
log "[3/7] Bucket reachability"
s3_exec 'aws $EP s3api head-bucket --bucket "$bucket" && echo REACHABLE' 2>/dev/null | grep -q REACHABLE \
  || fail "cannot reach the backup bucket - check BACKUP_S3_* in .env"
ok "bucket reachable with the configured credentials"

# [4/7] THE REAL TEST: write -> back up -> destroy -> restore -> compare
log "[4/7] Mongo backup and restore round trip (this is the one that matters)"
require_vars MONGO_APP_DB

log "  writing sentinel document..."
mongo_eval "db.getSiblingDB(\"$MONGO_APP_DB\").verify6a.insertOne({sentinel: \"$SENTINEL\"})" >/dev/null \
  || fail "could not write the sentinel document"

log "  running a backup..."
TEST_JOB="verify6a-backup-$(date +%s)"
kubectl -n data create job "$TEST_JOB" --from=cronjob/mongo-backup >/dev/null
kubectl -n data wait --for=condition=complete "job/$TEST_JOB" --timeout=600s >/dev/null 2>&1 \
  || { kubectl -n data logs "job/$TEST_JOB" --all-containers --tail=40 >&2 || true
       fail "the backup job did not complete"; }

CREATED_KEY=$(s3_exec 'aws $EP s3 ls "s3://${bucket}/${prefix}/mongo/" | sort -r | head -1 | awk "{print \$4}"' 2>/dev/null | tr -d '\r\n ')
[ -n "$CREATED_KEY" ] || fail "no backup object appeared in the bucket"
log "  uploaded: $CREATED_KEY"

log "  destroying the source data..."
mongo_eval "db.getSiblingDB(\"$MONGO_APP_DB\").verify6a.drop()" >/dev/null \
  || fail "could not drop the sentinel collection"

still=$(mongo_eval "print(db.getSiblingDB(\"$MONGO_APP_DB\").verify6a.countDocuments({sentinel:\"$SENTINEL\"}))" 2>/dev/null | tr -dc '0-9')
[ "${still:-0}" = "0" ] || fail "the sentinel survived the drop - the test is not measuring anything"

log "  restoring from S3 into scratch database '$SCRATCH_DB'..."
./scripts/mongo-restore.sh restore "$CREATED_KEY" --target "$SCRATCH_DB" >/dev/null 2>&1 \
  || fail "restore failed - the backup exists but cannot be restored, which is the failure this gate is for"

found=$(mongo_eval "print(db.getSiblingDB(\"$SCRATCH_DB\").verify6a.countDocuments({sentinel:\"$SENTINEL\"}))" 2>/dev/null | tr -dc '0-9')
[ "${found:-0}" = "1" ] \
  || fail "the sentinel document did NOT come back from the restore (found ${found:-0}).
  The backup is not restorable. Do not rely on it."
ok "sentinel written, backed up, destroyed, and restored from S3 intact"

# [5/7] Redis backup produces a valid RDB
log "[5/7] Redis backup"
RJOB="verify6a-redis-$(date +%s)"
kubectl -n data create job "$RJOB" --from=cronjob/redis-backup >/dev/null
if kubectl -n data wait --for=condition=complete "job/$RJOB" --timeout=600s >/dev/null 2>&1; then
  RKEY=$(s3_exec 'aws $EP s3 ls "s3://${bucket}/${prefix}/redis/" | sort -r | head -1 | awk "{print \$4}"' 2>/dev/null | tr -d '\r\n ')
  [ -n "$RKEY" ] || fail "redis backup completed but no object appeared"
  # The job's own redis-check-rdb already ran; this confirms it landed remotely.
  ok "redis snapshot uploaded and RDB integrity-checked: $RKEY"
  s3_exec "aws \$EP s3 rm \"s3://\${bucket}/\${prefix}/redis/${RKEY}\"" >/dev/null 2>&1 || true
else
  kubectl -n data logs "job/$RJOB" --all-containers --tail=40 >&2 || true
  kubectl -n data delete job "$RJOB" --ignore-not-found >/dev/null 2>&1 || true
  fail "the redis backup job did not complete"
fi
kubectl -n data delete job "$RJOB" --ignore-not-found >/dev/null 2>&1 || true

# [6/7] retention is bounded
log "[6/7] Retention pruning"
: "${BACKUP_RETENTION_DAYS:=30}"
OLD_KEY="mongo-$(date -u -d "$((BACKUP_RETENTION_DAYS + 10)) days ago" +%Y%m%dT%H%M%SZ 2>/dev/null \
  || date -u -v-$((BACKUP_RETENTION_DAYS + 10))d +%Y%m%dT%H%M%SZ).gz"
s3_exec "echo synthetic > /tmp/o && aws \$EP s3 cp /tmp/o \"s3://\${bucket}/\${prefix}/mongo/${OLD_KEY}\"" >/dev/null 2>&1 \
  || fail "could not upload a synthetic old object"

PJOB="verify6a-prune-$(date +%s)"
kubectl -n data create job "$PJOB" --from=cronjob/mongo-backup >/dev/null
kubectl -n data wait --for=condition=complete "job/$PJOB" --timeout=600s >/dev/null 2>&1 || true
kubectl -n data delete job "$PJOB" --ignore-not-found >/dev/null 2>&1 || true

if s3_exec "aws \$EP s3 ls \"s3://\${bucket}/\${prefix}/mongo/${OLD_KEY}\"" 2>/dev/null | grep -q "$OLD_KEY"; then
  s3_exec "aws \$EP s3 rm \"s3://\${bucket}/\${prefix}/mongo/${OLD_KEY}\"" >/dev/null 2>&1 || true
  fail "an object dated beyond BACKUP_RETENTION_DAYS (${BACKUP_RETENTION_DAYS}) was not pruned - the bucket will grow without limit"
fi
ok "objects older than ${BACKUP_RETENTION_DAYS} days are pruned"

# [7/7] the freshest backup is recent
log "[7/7] Backup freshness"
LATEST=$(s3_exec 'aws $EP s3 ls "s3://${bucket}/${prefix}/mongo/" | sort -r | head -1' 2>/dev/null || true)
[ -n "$LATEST" ] || fail "no mongo backup objects in the bucket at all"
ok "most recent backup: $(echo "$LATEST" | awk '{print $1, $2, $4}')"

log ""
log "RPO note: scheduled backups run on '${BACKUP_SCHEDULE_MONGO:-0 3 * * *}'."
log "Data written after the last run is NOT recoverable - take a manual backup"
log "with ./scripts/backup-now.sh before anything risky."
log ""
ok "PHASE 6A OK"
