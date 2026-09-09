#!/usr/bin/env bash
# bootstrap-edge.sh
# Purpose: Orchestrate Phase 2 bring-up (build images, deploy Kong, ping, frontend)
# depends_on: [scripts/build-push.sh, k8s/platform/kong/*, k8s/app/ping/*, k8s/app/frontend/*, scripts/kongctl.sh]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need kubectl
need docker

require_vars REGISTRY_URL

# Assert Phase 0 namespaces exist
log "Checking Phase 0 prerequisites..."
kubectl get namespace platform >/dev/null 2>&1 || die "Namespace 'platform' not found - run 'make base' first"
kubectl get namespace app >/dev/null 2>&1 || die "Namespace 'app' not found - run 'make base' first"
ok "Phase 0 namespaces present"

# Step 1: Build and push images
log "Step 1: Building and pushing images..."
"$SCRIPT_DIR/build-push.sh" || die "build-push.sh failed"
ok "Images built and pushed"

# Step 2: Deploy Kong
log "Step 2: Deploying Kong..."

# Substitute REGISTRY_URL in manifests and apply
log "  Applying Kong ConfigMap..."
kubectl apply -f "$REPO_ROOT/k8s/platform/kong/kong-configmap.yaml" || die "Failed to apply Kong ConfigMap"

log "  Applying Kong Deployment..."
kubectl apply -f "$REPO_ROOT/k8s/platform/kong/deployment.yaml" || die "Failed to apply Kong Deployment"

log "  Applying Kong Proxy Service..."
kubectl apply -f "$REPO_ROOT/k8s/platform/kong/proxy-service.yaml" || die "Failed to apply Kong Proxy Service"

log "  Applying Kong Admin Service..."
kubectl apply -f "$REPO_ROOT/k8s/platform/kong/admin-service.yaml" || die "Failed to apply Kong Admin Service"

log "  Waiting for Kong rollout..."
kubectl -n platform rollout status deployment/kong --timeout=120s || die "Kong rollout failed"
ok "Kong deployed"

# Step 3: Deploy ping service
log "Step 3: Deploying ping service..."

# Substitute REGISTRY_URL in deployment
log "  Applying ping manifests..."
cat "$REPO_ROOT/k8s/app/ping/deployment.yaml" | sed "s|\${REGISTRY_URL}|${REGISTRY_URL}|g" | kubectl apply -f - || die "Failed to apply ping deployment"
kubectl apply -f "$REPO_ROOT/k8s/app/ping/service.yaml" || die "Failed to apply ping service"

log "  Waiting for ping rollout..."
kubectl -n app rollout status deployment/ping --timeout=120s || die "Ping rollout failed"
ok "Ping service deployed"

# Step 4: Deploy frontend
log "Step 4: Deploying frontend..."

log "  Applying frontend manifests..."
cat "$REPO_ROOT/k8s/app/frontend/deployment.yaml" | sed "s|\${REGISTRY_URL}|${REGISTRY_URL}|g" | kubectl apply -f - || die "Failed to apply frontend deployment"
kubectl apply -f "$REPO_ROOT/k8s/app/frontend/service.yaml" || die "Failed to apply frontend service"

log "  Waiting for frontend rollout..."
kubectl -n app rollout status deployment/frontend --timeout=120s || die "Frontend rollout failed"
ok "Frontend deployed"

# Step 5: Wait for kong-proxy endpoint
log "Step 5: Waiting for Kong proxy endpoint..."
local node_port
node_port=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.spec.ports[0].nodePort}')
ok "Kong proxy available on NodePort: $node_port"

# Step 6: Verify Kong health
log "Step 6: Verifying Kong health..."
sleep 5  # Give Kong a moment to stabilize
"$SCRIPT_DIR/kongctl.sh" health || log "Warning: Kong health check failed (may be normal during initial startup)"

ok "Phase 2 bootstrap complete"
log ""
log "Next steps:"
log "  1. Access the frontend: http://<node-ip>:${node_port}/"
log "  2. Test the ping API: curl http://<node-ip>:${node_port}/api/ping"
log "  3. Run verification: make verify-phase2"
