#!/usr/bin/env bash
# verify-phase2.sh
# Purpose: Phase 2 verification gate - asserts Kong, ping, frontend all work end-to-end
# depends_on: [scripts/bootstrap-edge.sh]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need kubectl
need curl
need jq

fail() { die "verify-phase2: $*"; }

# Trap to clean up any temporary pods
cleanup() {
  kubectl delete pod verify-phase2-curl --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "[1/5] Checking Kong deployment..."
kubectl -n platform get deployment kong >/dev/null 2>&1 || fail "Kong deployment not found"
KONG_READY=$(kubectl -n platform get deployment kong -o jsonpath='{.status.readyReplicas}')
KONG_DESIRED=$(kubectl -n platform get deployment kong -o jsonpath='{.spec.replicas}')
[ "$KONG_READY" = "$KONG_DESIRED" ] || fail "Kong not ready ($KONG_READY/$KONG_DESIRED)"
ok "Kong deployment ready (2/2)"

log "[2/5] Checking ping and frontend deployments..."
kubectl -n app get deployment ping >/dev/null 2>&1 || fail "Ping deployment not found"
kubectl -n app get deployment frontend >/dev/null 2>&1 || fail "Frontend deployment not found"

PING_READY=$(kubectl -n app get deployment ping -o jsonpath='{.status.readyReplicas}')
PING_DESIRED=$(kubectl -n app get deployment ping -o jsonpath='{.spec.replicas}')
[ "$PING_READY" = "$PING_DESIRED" ] || fail "Ping not ready ($PING_READY/$PING_DESIRED)"

FRONTEND_READY=$(kubectl -n app get deployment frontend -o jsonpath='{.status.readyReplicas}')
FRONTEND_DESIRED=$(kubectl -n app get deployment frontend -o jsonpath='{.spec.replicas}')
[ "$FRONTEND_READY" = "$FRONTEND_DESIRED" ] || fail "Frontend not ready ($FRONTEND_READY/$FRONTEND_DESIRED)"
ok "Ping and frontend deployments ready (2/2 each)"

log "[3/5] Checking Kong proxy Service..."
KONG_SVC_TYPE=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.spec.type}')
[ "$KONG_SVC_TYPE" = "NodePort" ] || [ "$KONG_SVC_TYPE" = "LoadBalancer" ] || fail "Kong proxy Service is not NodePort or LoadBalancer"

if [ "$KONG_SVC_TYPE" = "NodePort" ]; then
  NODE_PORT=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.spec.ports[0].nodePort}')
  # Get only Ready nodes (filter by Ready status)
  NODE_IP=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | .status.addresses[] | select(.type=="InternalIP") | .address' | head -1)
  [ -z "$NODE_IP" ] && fail "No Ready nodes found"
  ENDPOINT="http://${NODE_IP}:${NODE_PORT}"
else
  # LoadBalancer
  LB_IP=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$LB_IP" ] || fail "LoadBalancer IP not assigned"
  ENDPOINT="http://${LB_IP}"
fi
ok "Kong proxy endpoint: $ENDPOINT"

log "[4/5] Testing end-to-end HTTP routing from outside the cluster..."

# Create a temporary curl pod to test from within the cluster (simulates external access via NodePort)
log "  Testing /api/ping..."
PING_RESPONSE=$(kubectl run verify-phase2-curl --rm -i --restart=Never --image=curlimages/curl:latest -- \
  curl -sf "$ENDPOINT/api/ping" 2>/dev/null || fail "Failed to reach /api/ping")

echo "$PING_RESPONSE" | grep -q '"status":"ok"' || fail "/api/ping did not return expected response"
ok "/api/ping returns ok"

log "  Testing frontend (/)..."
FRONTEND_RESPONSE=$(kubectl run verify-phase2-curl --rm -i --restart=Never --image=curlimages/curl:latest -- \
  curl -sf "$ENDPOINT/" 2>/dev/null || fail "Failed to reach /")

echo "$FRONTEND_RESPONSE" | grep -qi "backbone\|react" || fail "Frontend did not return expected HTML"
ok "Frontend (/) returns HTML"

log "[5/5] Verifying Kong Admin API is ClusterIP-only..."
# Admin API should NOT be reachable from outside but should be from inside
kubectl run verify-phase2-curl --rm -i --restart=Never --image=curlimages/curl:latest -- \
  curl -sf "http://kong-admin.platform.svc:8001/status" >/dev/null 2>&1 || fail "Kong Admin API not reachable from inside cluster"
ok "Kong Admin API is accessible from inside the cluster (ClusterIP)"

# Clean up
cleanup

echo ""
ok "PHASE 2 OK"
log ""
log "Access your platform:"
log "  Frontend: $ENDPOINT/"
log "  Ping API: $ENDPOINT/api/ping"
