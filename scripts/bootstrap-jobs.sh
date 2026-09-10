#!/usr/bin/env bash
# bootstrap-jobs.sh
# Purpose: Build and deploy Phase 4 (async jobs) - jobs-api + worker
# Depends on: Phase 0 (cluster), Phase 1 (mongodb + redis), Phase 3 (auth)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl docker

log "Phase 4: Bootstrapping async jobs (jobs-api + worker)"

# Assert prerequisites
log "Checking prerequisites..."
kubectl get namespace platform data app > /dev/null || die "Namespaces missing - run 'make phase0'"
kubectl -n data get statefulset mongodb redis > /dev/null || die "Phase 1 not deployed - run 'make phase1'"
kubectl -n app get deployment auth > /dev/null || die "Phase 3 not deployed - run 'make phase3'"

# Check secrets exist
kubectl -n app get secret mongodb-credentials redis-password > /dev/null || die "Data secrets missing in app namespace"

# Get registry URL and generate tag
require_vars REGISTRY_URL
TAG="$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"

log "Building and pushing images (tag: $TAG)..."

# Build jobs-api
log "  Building jobs-api..."
docker build \
  -t "$REGISTRY_URL/jobs-api:$TAG" \
  -t "$REGISTRY_URL/jobs-api:latest" \
  -f services/jobs-api/Dockerfile \
  . || die "Failed to build jobs-api image"

log "  Pushing jobs-api..."
docker push "$REGISTRY_URL/jobs-api:$TAG" || die "Failed to push jobs-api:$TAG"
docker push "$REGISTRY_URL/jobs-api:latest" || die "Failed to push jobs-api:latest"

# Build worker
log "  Building worker..."
docker build \
  -t "$REGISTRY_URL/worker:$TAG" \
  -t "$REGISTRY_URL/worker:latest" \
  -f services/worker/Dockerfile \
  . || die "Failed to build worker image"

log "  Pushing worker..."
docker push "$REGISTRY_URL/worker:$TAG" || die "Failed to push worker:$TAG"
docker push "$REGISTRY_URL/worker:latest" || die "Failed to push worker:latest"

# Update image references in manifests
log "Updating image references in manifests..."
sed -i.bak "s|REGISTRY_URL|$REGISTRY_URL|g" k8s/app/jobs-api/deployment.yaml
sed -i.bak "s|REGISTRY_URL|$REGISTRY_URL|g" k8s/app/worker/deployment.yaml

# Apply jobs-api
log "Deploying jobs-api..."
kubectl apply -f k8s/app/jobs-api/deployment.yaml || die "Failed to apply jobs-api deployment"
kubectl apply -f k8s/app/jobs-api/service.yaml || die "Failed to apply jobs-api service"

log "Waiting for jobs-api rollout..."
kubectl -n app rollout status deployment/jobs-api --timeout=120s || die "jobs-api rollout failed"

# Apply worker
log "Deploying worker..."
kubectl apply -f k8s/app/worker/deployment.yaml || die "Failed to apply worker deployment"
kubectl apply -f k8s/app/worker/hpa.yaml || die "Failed to apply worker HPA"

log "Waiting for worker rollout..."
kubectl -n app rollout status deployment/worker --timeout=120s || die "worker rollout failed"

# Restore manifests
mv k8s/app/jobs-api/deployment.yaml.bak k8s/app/jobs-api/deployment.yaml
mv k8s/app/worker/deployment.yaml.bak k8s/app/worker/deployment.yaml

# Update Kong config
log "Updating Kong configuration..."
kubectl apply -f k8s/platform/kong/kong-configmap.yaml || die "Failed to update Kong config"

log "Restarting Kong to load new routes..."
kubectl -n platform rollout restart deployment/kong || die "Failed to restart Kong"
kubectl -n platform rollout status deployment/kong --timeout=90s || die "Kong rollout failed"

# Verify routes
log "Verifying Kong routes..."
sleep 5  # Give Kong a moment to reload
if command -v scripts/kongctl.sh &> /dev/null; then
  scripts/kongctl.sh routes | grep -q "jobs-api" && ok "Kong /api/jobs route configured" || log "Warning: Could not verify Kong route"
fi

ok "Phase 4 bootstrap complete"
log ""
log "Services deployed:"
log "  - jobs-api: 2 replicas in app namespace"
log "  - worker: auto-scaling (1-10 replicas) in app namespace"
log ""
log "Kong routes:"
log "  POST/GET /api/jobs - Job queue API (requires auth)"
log ""
log "Next: Run 'make verify-phase4' to verify the deployment"
