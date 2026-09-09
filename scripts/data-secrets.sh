#!/usr/bin/env bash
# Create the Phase 1 (data layer) Kubernetes Secrets from .env. Idempotent.
# Never echoes secret values.
# depends_on: [k8s/base/namespaces.yaml, .env.example, scripts/create-secrets.sh, scripts/lib.sh]
#
# Creates in namespace `data`:
#   mongodb-credentials : root-username/root-password + app-username/app-password/app-db
#   redis-password      : password
#
# Values come from .env (see the "Phase 1 - Data layer" block in .env.example).
# This script does NOT generate anything - it fails if a value is blank, so the
# operator sets and records them deliberately. Re-running with changed values
# updates the Secret objects; running pods pick the change up only on restart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need kubectl

kubectl get ns data >/dev/null 2>&1 \
  || die "namespace 'data' missing - run 'make base' first"

require_vars \
  MONGO_ROOT_USER MONGO_ROOT_PASSWORD \
  MONGO_APP_USER MONGO_APP_PASSWORD MONGO_APP_DB \
  REDIS_PASSWORD

# Idempotent create-or-update. Values are passed on stdin via --from-literal,
# rendered to a manifest client-side, then applied - never printed.
apply_secret() {
  local name="$1"; shift
  kubectl create secret generic "$name" \
    --namespace data \
    "$@" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

apply_secret mongodb-credentials \
  --from-literal=root-username="$MONGO_ROOT_USER" \
  --from-literal=root-password="$MONGO_ROOT_PASSWORD" \
  --from-literal=app-username="$MONGO_APP_USER" \
  --from-literal=app-password="$MONGO_APP_PASSWORD" \
  --from-literal=app-db="$MONGO_APP_DB"
ok "secret data/mongodb-credentials applied (5 keys)"

apply_secret redis-password \
  --from-literal=password="$REDIS_PASSWORD"
ok "secret data/redis-password applied (1 key)"

log "note: running pods do NOT reload - 'kubectl -n data rollout restart statefulset/<name>' after a rotation"
