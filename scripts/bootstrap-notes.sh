#!/usr/bin/env bash
# bootstrap-notes.sh
# Purpose: Build and deploy the Notes CRUD demo app (notes-api + notes-worker)
# Depends on: Phase 0 (cluster), Phase 1 (mongodb + redis), Phase 3 (auth, for
#             the jwt-public-key Secret both services mount)
#
# Self-contained test app proving backbone hosts an arbitrary container on
# the existing gateway/database/queue infrastructure - a Python Flask API
# (notes-api) and a Python BullMQ consumer (notes-worker), talking to the
# same MongoDB and Redis every other phase already deployed, on their own
# "notes" queue so this stays fully removable without touching the
# reference services.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl docker jq

log "Notes demo: Bootstrapping notes-api + notes-worker"

# Assert prerequisites
log "Checking prerequisites..."
kubectl get namespace platform data app > /dev/null || die "Namespaces missing - run 'make phase0'"
kubectl -n data get statefulset mongodb redis > /dev/null || die "Phase 1 not deployed - run 'make phase1'"
kubectl -n app get deployment auth > /dev/null || die "Phase 3 not deployed - run 'make phase3'"

# mongodb-credentials/redis-password/jwt-public-key must already be mirrored
# into `app` by bootstrap-auth.sh (Phase 3) - see fb3304d and the JWT
# verification fix alongside this app. Check rather than re-mirror here:
# these are Phase 3's responsibility, not this demo app's.
kubectl -n app get secret mongodb-credentials redis-password jwt-public-key > /dev/null \
  || die "Required secrets missing in app namespace - run 'make phase3' first"

require_vars REGISTRY_URL
TAG="$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"

log "Building and pushing images (tag: $TAG)..."

# --no-cache: see bootstrap-jobs.sh for why this is non-negotiable here -
# the legacy Docker builder has repeatedly reused a stale COPY layer even
# when the copied source changed, silently shipping old code as if the
# build succeeded.
log "  Building notes-api..."
docker build --no-cache \
  -t "$REGISTRY_URL/backbone-notes-api:$TAG" \
  -t "$REGISTRY_URL/backbone-notes-api:latest" \
  -f services/notes-api/Dockerfile \
  . || die "Failed to build notes-api image"

log "  Pushing notes-api..."
docker push "$REGISTRY_URL/backbone-notes-api:$TAG" || die "Failed to push notes-api:$TAG"
docker push "$REGISTRY_URL/backbone-notes-api:latest" || die "Failed to push notes-api:latest"

log "  Building notes-worker..."
docker build --no-cache \
  -t "$REGISTRY_URL/backbone-notes-worker:$TAG" \
  -t "$REGISTRY_URL/backbone-notes-worker:latest" \
  -f services/notes-worker/Dockerfile \
  . || die "Failed to build notes-worker image"

log "  Pushing notes-worker..."
docker push "$REGISTRY_URL/backbone-notes-worker:$TAG" || die "Failed to push notes-worker:$TAG"
docker push "$REGISTRY_URL/backbone-notes-worker:latest" || die "Failed to push notes-worker:latest"

# These are tracked files, temporarily mutated in place - see
# bootstrap-jobs.sh for why the restore must be unconditional (a trap on
# EXIT), not a manual step after the last kubectl call.
restore_manifests() {
  [ -f k8s/app/notes-api/deployment.yaml.bak ] && mv k8s/app/notes-api/deployment.yaml.bak k8s/app/notes-api/deployment.yaml
  [ -f k8s/app/notes-worker/deployment.yaml.bak ] && mv k8s/app/notes-worker/deployment.yaml.bak k8s/app/notes-worker/deployment.yaml
}
trap restore_manifests EXIT

log "Updating image references in manifests..."
sed -i.bak "s|REGISTRY_URL|$REGISTRY_URL|g" k8s/app/notes-api/deployment.yaml
sed -i.bak "s|REGISTRY_URL|$REGISTRY_URL|g" k8s/app/notes-worker/deployment.yaml

log "Deploying notes-api..."
kubectl apply -f k8s/app/notes-api/deployment.yaml || die "Failed to apply notes-api deployment"
kubectl apply -f k8s/app/notes-api/service.yaml || die "Failed to apply notes-api service"

log "Waiting for notes-api rollout..."
kubectl -n app rollout status deployment/notes-api --timeout=120s || die "notes-api rollout failed"

log "Deploying notes-worker..."
kubectl apply -f k8s/app/notes-worker/deployment.yaml || die "Failed to apply notes-worker deployment"

log "Waiting for notes-worker rollout..."
kubectl -n app rollout status deployment/notes-worker --timeout=120s || die "notes-worker rollout failed"

# Manifests are restored by the EXIT trap set above, whether this script
# succeeds or dies from here on.

log "Updating Kong configuration..."
kubectl apply -f k8s/platform/kong/kong-configmap.yaml || die "Failed to update Kong config"

log "Restarting Kong to load new routes..."
kubectl -n platform rollout restart deployment/kong || die "Failed to restart Kong"
kubectl -n platform rollout status deployment/kong --timeout=90s || die "Kong rollout failed"

log "Verifying Kong routes..."
sleep 5
if command -v scripts/kongctl.sh &> /dev/null; then
  scripts/kongctl.sh routes | grep -q "notes-api" && ok "Kong /api/notes route configured" || log "Warning: Could not verify Kong route"
fi

ok "Notes demo bootstrap complete"
log ""
log "Services deployed:"
log "  - notes-api: 2 replicas in app namespace"
log "  - notes-worker: 1 replica in app namespace"
log ""
log "Kong routes:"
log "  POST/GET /api/notes - Notes CRUD demo (requires auth)"
log ""
log "Next: run scripts/verify-notes.sh, or test by hand:"
log "  TOKEN=\$(curl -s -X POST \$ENDPOINT/api/auth/login -H 'Content-Type: application/json' -d '{\"email\":\"you@example.com\",\"password\":\"...\"}' | jq -r '.accessToken')"
log "  curl -X POST \$ENDPOINT/api/notes -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' -d '{\"title\":\"hi\",\"body\":\"first note\"}'"
