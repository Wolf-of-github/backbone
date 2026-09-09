#!/usr/bin/env bash
# Phase 1 orchestrator: secrets -> Redis -> MongoDB -> Mongo app-user init Job.
# Idempotent; safe to re-run after a partial failure.
# depends_on: [scripts/data-secrets.sh,
#              k8s/data/redis/conf-configmap.yaml, k8s/data/redis/statefulset.yaml,
#              k8s/data/redis/service.yaml,
#              k8s/data/mongodb/mongod-conf-configmap.yaml,
#              k8s/data/mongodb/init-configmap.yaml, k8s/data/mongodb/statefulset.yaml,
#              k8s/data/mongodb/service.yaml, k8s/data/mongodb/init-job.yaml]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need kubectl

K8S="$REPO_ROOT/k8s/data"

# --- preconditions (Phase 0 substrate) ------------------------------------
kubectl get ns data >/dev/null 2>&1 \
  || die "namespace 'data' missing - run 'make base' first"
kubectl get storageclass local-path \
  -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null \
  | grep -q true \
  || die "local-path is not the default StorageClass - run 'make base' first"

# --- 1. secrets ------------------------------------------------------------
log "[1/4] data-layer secrets"
"$SCRIPT_DIR/data-secrets.sh"

# --- 2. Redis (no init step - bring it up first) -------------------------
log "[2/4] Redis"
kubectl apply -f "$K8S/redis/conf-configmap.yaml" >/dev/null
kubectl apply -f "$K8S/redis/statefulset.yaml" >/dev/null
kubectl apply -f "$K8S/redis/service.yaml" >/dev/null
kubectl -n data rollout status statefulset/redis --timeout=120s
ok "Redis ready"

# --- 3. MongoDB ---------------------------------------------------------
log "[3/4] MongoDB"
kubectl apply -f "$K8S/mongodb/mongod-conf-configmap.yaml" >/dev/null
kubectl apply -f "$K8S/mongodb/init-configmap.yaml" >/dev/null
kubectl apply -f "$K8S/mongodb/statefulset.yaml" >/dev/null
kubectl apply -f "$K8S/mongodb/service.yaml" >/dev/null
kubectl -n data rollout status statefulset/mongodb --timeout=180s
ok "MongoDB ready"

# --- 4. Mongo app-user init Job ----------------------------------------
log "[4/4] MongoDB app-user init"
# Re-runnable: clear any prior Job (spec is immutable) then re-create.
kubectl -n data delete job mongodb-init --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl apply -f "$K8S/mongodb/init-job.yaml" >/dev/null
kubectl -n data wait --for=condition=complete job/mongodb-init --timeout=120s \
  || die "mongodb-init Job did not complete - 'kubectl -n data logs job/mongodb-init'"
ok "app user + database created"

printf '\n\033[32mdata layer up\033[0m - run: make verify-phase1\n' >&2
