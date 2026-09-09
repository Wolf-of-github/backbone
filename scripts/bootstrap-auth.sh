#!/usr/bin/env bash
# bootstrap-auth.sh
# Purpose: Orchestrate Phase 3 auth deployment
# Depends on: jwt-keys.sh, build-push.sh, k8s/app/auth/*, k8s/platform/kong/*

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

load_env
need kubectl docker

log "Phase 3 - Auth deployment starting..."

# Verify Phase 0, 1, 2 are healthy
log "Checking Phase 0 prerequisites..."
kubectl get ns platform data app >/dev/null 2>&1 || die "Namespaces missing. Run 'make base' first."

log "Checking Phase 1 data layer..."
kubectl -n data get statefulset/mongodb statefulset/redis >/dev/null 2>&1 || die "MongoDB/Redis not found. Run 'make phase1' first."

log "Checking Phase 2 edge..."
kubectl -n platform get deployment/kong >/dev/null 2>&1 || die "Kong not found. Run 'make phase2' first."
kubectl -n app get deployment/ping deployment/frontend >/dev/null 2>&1 || die "Ping/Frontend not found. Run 'make phase2' first."

# Step 1: Generate JWT keypair
log "[1/7] Generating JWT keypair..."
"${SCRIPT_DIR}/jwt-keys.sh"
ok "JWT keys ready"

# Step 2: Create auth ConfigMap with settings from .env
log "[2/7] Creating auth-config ConfigMap..."
JWT_ACCESS_EXPIRY="${JWT_ACCESS_EXPIRY:-15m}"
JWT_REFRESH_EXPIRY="${JWT_REFRESH_EXPIRY:-7d}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost:30080}"

kubectl -n app create configmap auth-config \
  --from-literal=JWT_ACCESS_EXPIRY="${JWT_ACCESS_EXPIRY}" \
  --from-literal=JWT_REFRESH_EXPIRY="${JWT_REFRESH_EXPIRY}" \
  --from-literal=FRONTEND_URL="${FRONTEND_URL}" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "auth-config ConfigMap created"

# Step 3: Update Kong configuration
log "[3/7] Updating Kong configuration..."
kubectl apply -f "${REPO_ROOT}/k8s/platform/kong/kong-configmap.yaml"
kubectl -n platform rollout restart deployment/kong
kubectl -n platform rollout status deployment/kong --timeout=120s
ok "Kong updated with auth routes"

# Step 4: Build and push auth service image
log "[4/7] Building and pushing auth service image..."
cd "${REPO_ROOT}"

# Build auth image
docker build -t "${REGISTRY_URL}/backbone-auth:latest" \
  -t "${REGISTRY_URL}/backbone-auth:$(git rev-parse --short HEAD 2>/dev/null || echo 'dev')" \
  services/auth/

# Push images
docker push "${REGISTRY_URL}/backbone-auth:latest"
docker push "${REGISTRY_URL}/backbone-auth:$(git rev-parse --short HEAD 2>/dev/null || echo 'dev')" || true

ok "Auth service image built and pushed"

# Step 5: Deploy auth service
log "[5/7] Deploying auth service..."

# Update deployment with registry URL
sed "s|REGISTRY_URL|${REGISTRY_URL}|g" "${REPO_ROOT}/k8s/app/auth/deployment.yaml" | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/k8s/app/auth/service.yaml"

kubectl -n app rollout status deployment/auth --timeout=120s
ok "Auth service deployed"

# Step 6: Rebuild and redeploy ping (with auth middleware)
log "[6/7] Rebuilding ping service with auth..."

docker build -t "${REGISTRY_URL}/backbone-ping:latest" \
  -f services/ping/Dockerfile \
  --build-arg BUILDCONTEXT=. \
  .

docker push "${REGISTRY_URL}/backbone-ping:latest"
kubectl -n app rollout restart deployment/ping
kubectl -n app rollout status deployment/ping --timeout=120s
ok "Ping service updated with auth"

# Step 7: Rebuild and redeploy frontend (with login/register)
log "[7/7] Rebuilding frontend with auth UI..."

docker build -t "${REGISTRY_URL}/backbone-frontend:latest" \
  services/frontend/

docker push "${REGISTRY_URL}/backbone-frontend:latest"
kubectl -n app rollout restart deployment/frontend
kubectl -n app rollout status deployment/frontend --timeout=120s
ok "Frontend updated with auth UI"

ok "Phase 3 auth deployment complete!"
log "You can now run 'make verify-phase3' to test end-to-end authentication"
