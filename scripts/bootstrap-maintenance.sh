#!/usr/bin/env bash
# bootstrap-maintenance.sh
# Purpose: Phase 6B - deploy the maintenance page, its state, and the RBAC the
#          auth service needs to end maintenance over HTTP.
# depends_on: [k8s/platform/maintenance/*, k8s/app/auth/rbac.yaml, scripts/lib.sh]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl

kubectl get ns platform >/dev/null 2>&1 || die "namespace 'platform' missing - run 'make base' first"
kubectl -n platform get deployment kong >/dev/null 2>&1 \
  || die "Kong not found - Phase 2 must be deployed first"

# ---------------------------------------------------------------------------
# 1. The page and its pod
# ---------------------------------------------------------------------------
log "Deploying the maintenance page..."
kubectl apply -f k8s/platform/maintenance/page-configmap.yaml >/dev/null
kubectl apply -f k8s/platform/maintenance/deployment.yaml >/dev/null

# The state ConfigMap must NOT be overwritten if maintenance is currently on -
# that would discard saved_kong_config and strand the cluster showing a 503
# with no way back except hand-editing Kong.
if kubectl -n platform get configmap maintenance-state >/dev/null 2>&1; then
  current=$(kubectl -n platform get configmap maintenance-state -o jsonpath='{.data.enabled}' 2>/dev/null || echo "")
  if [ "$current" = "on" ]; then
    log "maintenance-state exists and maintenance is ON - leaving it untouched"
  else
    log "maintenance-state exists - leaving it as is"
  fi
else
  kubectl apply -f k8s/platform/maintenance/state-configmap.yaml >/dev/null
  ok "maintenance-state initialised (off)"
fi

kubectl -n platform rollout status deployment/maintenance --timeout=120s >/dev/null \
  || die "the maintenance page did not become Ready.
  Check: kubectl -n platform logs deploy/maintenance --tail=30"
ok "maintenance page Running"

# ---------------------------------------------------------------------------
# 2. RBAC for the auth service's off-endpoint
# ---------------------------------------------------------------------------
log "Applying auth RBAC (two named ConfigMaps + restarting Kong, nothing else)..."
kubectl apply -f k8s/app/auth/rbac.yaml >/dev/null
ok "ServiceAccount/Role/RoleBinding applied"

# ---------------------------------------------------------------------------
# 3. Redeploy auth so it picks up the ServiceAccount and the new route
# ---------------------------------------------------------------------------
sa=$(kubectl -n app get deployment auth -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "")
if [ "$sa" != "auth" ]; then
  log "Updating the auth Deployment to use the 'auth' ServiceAccount..."
  ./scripts/apply-app-manifests.sh auth >/dev/null \
    || die "could not apply the auth manifests"
fi

log ""
log "The /internal/maintenance route needs the auth service image to include"
log "src/routes/maintenance.js. If you have not rebuilt auth since Phase 6B:"
log "  make build-push && make apply-app"

# ---------------------------------------------------------------------------
# 4. Install the CLI on PATH if possible - otherwise say where it is
# ---------------------------------------------------------------------------
log ""
ok "Maintenance mode ready"
log ""
log "  ./scripts/maintenance status"
log "  ./scripts/maintenance on --reason \"database migration\" [--pause-queues]"
log "  ./scripts/maintenance off"
log ""
log "During maintenance these stay reachable, so you cannot lock yourself out:"
log "  /api/auth/login, /internal/maintenance, /.well-known/acme-challenge"
log ""
log "The HTTP off-switch needs an admin user. Promote one with:"
log "  kubectl -n data exec -it statefulset/mongodb -- mongosh \\"
log "    \"mongodb://<root-user>:<pw>@localhost/${MONGO_APP_DB:-backbone}?authSource=admin\" \\"
log "    --eval 'db.users.updateOne({email:\"you@example.com\"},{\$addToSet:{roles:\"admin\"}})'"
