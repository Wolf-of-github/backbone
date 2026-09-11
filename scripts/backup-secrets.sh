#!/usr/bin/env bash
# backup-secrets.sh
# Purpose: Phase 6A - create the S3 credential the backup CronJobs upload with.
# depends_on: [k8s/base/namespaces.yaml, scripts/create-secrets.sh, scripts/lib.sh]
#
# Plugs into the create-secrets.sh convention from Phase 0: values come from
# .env (gitignored), the write is idempotent, and nothing is ever echoed.
#
# This key can write AND delete in the backup bucket, so it is exactly as
# sensitive as the database passwords it protects. Scope it to one bucket.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl

kubectl get ns data >/dev/null 2>&1 \
  || die "namespace 'data' missing - run 'make base' first"

require_vars BACKUP_S3_BUCKET BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY

: "${BACKUP_S3_REGION:=us-east-1}"
: "${BACKUP_S3_PREFIX:=backbone}"
: "${BACKUP_S3_ENDPOINT:=}"

kubectl -n data create secret generic backup-s3-credentials \
  --from-literal=endpoint="$BACKUP_S3_ENDPOINT" \
  --from-literal=bucket="$BACKUP_S3_BUCKET" \
  --from-literal=region="$BACKUP_S3_REGION" \
  --from-literal=access-key="$BACKUP_S3_ACCESS_KEY" \
  --from-literal=secret-key="$BACKUP_S3_SECRET_KEY" \
  --from-literal=prefix="$BACKUP_S3_PREFIX" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

ok "secret/backup-s3-credentials (ns data)"
log "Rotating: edit .env, re-run this, then restart nothing - CronJobs read the"
log "secret fresh on each run, so the next scheduled backup picks it up."
