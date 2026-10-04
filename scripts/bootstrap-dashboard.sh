#!/usr/bin/env bash
# bootstrap-dashboard.sh
# Purpose: Build and deploy Phase 7 (cluster dashboard) - dashboard-api + Kong route
# Depends on: Phase 0 (cluster), Phase 2 (Kong), Phase 3 (auth + jwt-keypair secret)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl docker

log "Phase 7: Bootstrapping cluster dashboard"

# --- prerequisites ----------------------------------------------------------
log "Checking prerequisites..."
kubectl get namespace app platform observability >/dev/null \
  || die "Namespaces missing - run 'make phase0'"
kubectl -n platform get deployment kong >/dev/null \
  || die "Kong not deployed - run 'make phase2'"
kubectl -n app get deployment auth >/dev/null \
  || die "Auth not deployed - run 'make phase3'"

# The service mounts this and REFUSES TO START without it (by design - see
# issues.txt SEC-1). Checking here turns a CrashLoopBackOff into a clear
# message now.
kubectl -n app get secret jwt-keypair >/dev/null \
  || die "Secret jwt-keypair missing in ns app - run 'make phase3' (scripts/jwt-keys.sh)"
kubectl -n app get secret jwt-keypair -o jsonpath='{.data.public-key}' | grep -q . \
  || die "Secret jwt-keypair has no 'public-key' entry"

# Maintenance mode saves and restores the Kong ConfigMap wholesale, so a route
# added while it is ON is silently discarded when it goes off (issues.txt
# BUILD-3). Refuse rather than produce a route that vanishes later.
MAINT=$(kubectl -n platform get configmap maintenance-state -o jsonpath='{.data.enabled}' 2>/dev/null || echo "off")
[ "$MAINT" != "on" ] || die "Maintenance mode is ON. The Kong route added now would be reverted by
  'maintenance off' restoring its saved config. Run './scripts/maintenance off' first."

# --- build ------------------------------------------------------------------
require_vars REGISTRY_URL
log "Building and pushing dashboard-api..."
# build-push.sh already knows the repo-root build context (dashboard-api copies
# services/common) and uses --no-cache for the stale-layer bug in BUILD-1.
"$REPO_ROOT/scripts/build-push.sh" dashboard-api

# --- RBAC -------------------------------------------------------------------
# Applied before the Deployment: a pod that starts without its ServiceAccount
# bindings gets 403 on every list and fails readiness, which looks like a bug
# in the service rather than missing RBAC.
log "Applying RBAC..."
kubectl apply -f k8s/app/dashboard-api/rbac.yaml

# --- workload ---------------------------------------------------------------
log "Applying manifests..."
"$REPO_ROOT/scripts/apply-app-manifests.sh" dashboard-api

# --- Kong route -------------------------------------------------------------
log "Adding the /api/cluster route to Kong..."
kubectl apply -f k8s/platform/kong/kong-configmap.yaml

# Kong is DB-less and reads its declarative config at startup, so the route
# only takes effect after a restart. Same mechanism maintenance.js uses.
kubectl -n platform rollout restart deployment/kong
kubectl -n platform rollout status deployment/kong --timeout=180s \
  || die "Kong did not come back after the config change.
  Inspect: kubectl -n platform logs -l app=kong --tail=50
  A malformed kong.yaml makes Kong refuse to start - check the ConfigMap."

log ""
ok "Phase 7 bootstrapped"
log "Verify with: make verify-phase7"
log ""
log "The dashboard is in the existing frontend, visible to admin users only."
log "Log in as \$ADMIN_EMAIL and use 'Show cluster dashboard'."
