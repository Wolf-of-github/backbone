#!/usr/bin/env bash
# verify-phase3.sh
# Purpose: Phase 3 verification gate - tests auth end-to-end
# Depends on: bootstrap-auth.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

load_env

PASSED=0
FAILED=0

fail() {
  echo "ERROR verify-phase3: $*" >&2
  ((FAILED++))
  return 1
}

check() {
  local num=$1
  local total=$2
  local desc=$3
  shift 3

  printf "[$num/$total] %-40s" "$desc"

  if "$@" >/dev/null 2>&1; then
    ok "OK"
    ((PASSED++))
    return 0
  else
    echo "FAIL"
    ((FAILED++))
    return 1
  fi
}

log "Phase 3 verification starting..."

# Get Kong endpoint
NODE_IP=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | .status.addresses[] | select(.type=="InternalIP") | .address' | head -1)
KONG_PORT=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.spec.ports[?(@.name=="proxy")].nodePort}')
ENDPOINT="http://${NODE_IP}:${KONG_PORT}"

if [ -z "$NODE_IP" ] || [ -z "$KONG_PORT" ]; then
  fail "Could not determine Kong endpoint"
  exit 1
fi

log "Testing against endpoint: $ENDPOINT"

# Cleanup function
cleanup() {
  rm -f /tmp/verify-phase3-*.json
}
trap cleanup EXIT

# [1/8] Auth deployment status
log "[1/8] Auth Deployment status"
kubectl -n app get deployment/auth >/dev/null 2>&1 || fail "Auth deployment not found"
kubectl -n app rollout status deployment/auth --timeout=10s >/dev/null 2>&1 || fail "Auth deployment not ready"
kubectl -n app get svc/auth >/dev/null 2>&1 || fail "Auth service not found"
ok "Auth deployment ready (2/2)"

# [2/8] JWT secrets exist
log "[2/8] JWT secrets"
kubectl -n app get secret/jwt-keypair >/dev/null 2>&1 || fail "jwt-keypair secret not found in app namespace"
kubectl -n platform get secret/jwt-public-key >/dev/null 2>&1 || fail "jwt-public-key secret not found in platform namespace"
ok "JWT secrets present"

# [3/8] User registration
log "[3/8] User registration"
TEST_EMAIL="test-$(date +%s)@example.com"
TEST_PASSWORD="testpass123"

REGISTER_RESPONSE=$(curl -s -X POST "${ENDPOINT}/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${TEST_EMAIL}\",\"password\":\"${TEST_PASSWORD}\"}" \
  -w "\n%{http_code}")

REGISTER_CODE=$(echo "$REGISTER_RESPONSE" | tail -1)
if [ "$REGISTER_CODE" != "201" ]; then
  fail "Registration failed (HTTP $REGISTER_CODE)"
else
  ok "Registration successful"
fi

# [4/8] User login
log "[4/8] User login and token issuance"
LOGIN_RESPONSE=$(curl -s -X POST "${ENDPOINT}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${TEST_EMAIL}\",\"password\":\"${TEST_PASSWORD}\"}")

ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.accessToken // empty')
REFRESH_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.refreshToken // empty')

if [ -z "$ACCESS_TOKEN" ] || [ -z "$REFRESH_TOKEN" ]; then
  fail "Login failed - no tokens returned"
else
  ok "Login successful, tokens issued"
fi

# [5/8] /api/auth/me with valid token
log "[5/8] Token verification (/api/auth/me)"
ME_RESPONSE=$(curl -s "${ENDPOINT}/api/auth/me" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -w "\n%{http_code}")

ME_CODE=$(echo "$ME_RESPONSE" | tail -1)
if [ "$ME_CODE" != "200" ]; then
  fail "/api/auth/me with token failed (HTTP $ME_CODE)"
else
  ok "/api/auth/me with token returns 200"
fi

# [5b/8] /api/auth/me without token = 401
ME_NOAUTH=$(curl -s "${ENDPOINT}/api/auth/me" -w "\n%{http_code}")
ME_NOAUTH_CODE=$(echo "$ME_NOAUTH" | tail -1)
if [ "$ME_NOAUTH_CODE" != "401" ]; then
  fail "/api/auth/me without token should return 401, got $ME_NOAUTH_CODE"
else
  ok "/api/auth/me without token returns 401"
fi

# [6/8] Protected route (/api/ping) requires auth
log "[6/8] Protected route enforcement (/api/ping)"
PING_WITH_TOKEN=$(curl -s "${ENDPOINT}/api/ping" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -w "\n%{http_code}")
PING_TOKEN_CODE=$(echo "$PING_WITH_TOKEN" | tail -1)

PING_WITHOUT_TOKEN=$(curl -s "${ENDPOINT}/api/ping" -w "\n%{http_code}")
PING_NOTOKEN_CODE=$(echo "$PING_WITHOUT_TOKEN" | tail -1)

if [ "$PING_TOKEN_CODE" != "200" ]; then
  fail "/api/ping with token should return 200, got $PING_TOKEN_CODE"
elif [ "$PING_NOTOKEN_CODE" != "401" ]; then
  fail "/api/ping without token should return 401, got $PING_NOTOKEN_CODE"
else
  ok "/api/ping requires valid token"
fi

# [7/8] Token refresh
log "[7/8] Token refresh and rotation"
REFRESH_RESPONSE=$(curl -s -X POST "${ENDPOINT}/api/auth/refresh" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"${REFRESH_TOKEN}\"}" \
  -w "\n%{http_code}")

REFRESH_CODE=$(echo "$REFRESH_RESPONSE" | tail -1)
NEW_ACCESS_TOKEN=$(echo "$REFRESH_RESPONSE" | sed '$d' | jq -r '.accessToken // empty')
NEW_REFRESH_TOKEN=$(echo "$REFRESH_RESPONSE" | sed '$d' | jq -r '.refreshToken // empty')

if [ "$REFRESH_CODE" != "200" ] || [ -z "$NEW_ACCESS_TOKEN" ] || [ -z "$NEW_REFRESH_TOKEN" ]; then
  fail "Token refresh failed (HTTP $REFRESH_CODE)"
else
  # Try using old refresh token again (should fail - single use)
  OLD_REFRESH=$(curl -s -X POST "${ENDPOINT}/api/auth/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"refreshToken\":\"${REFRESH_TOKEN}\"}" \
    -w "\n%{http_code}")
  OLD_REFRESH_CODE=$(echo "$OLD_REFRESH" | tail -1)

  if [ "$OLD_REFRESH_CODE" = "401" ]; then
    ok "Token refresh works, single-use enforced"
  else
    fail "Old refresh token should be rejected, got HTTP $OLD_REFRESH_CODE"
  fi
fi

# [8/8] Logout
log "[8/8] Logout and token revocation"
LOGOUT_RESPONSE=$(curl -s -X POST "${ENDPOINT}/api/auth/logout" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"${NEW_REFRESH_TOKEN}\"}" \
  -w "\n%{http_code}")

LOGOUT_CODE=$(echo "$LOGOUT_RESPONSE" | tail -1)
if [ "$LOGOUT_CODE" != "200" ]; then
  fail "Logout failed (HTTP $LOGOUT_CODE)"
else
  # Try using logged-out token
  REVOKED_REFRESH=$(curl -s -X POST "${ENDPOINT}/api/auth/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"refreshToken\":\"${NEW_REFRESH_TOKEN}\"}" \
    -w "\n%{http_code}")
  REVOKED_CODE=$(echo "$REVOKED_REFRESH" | tail -1)

  if [ "$REVOKED_CODE" = "401" ]; then
    ok "Logout successful, token revoked"
  else
    fail "Revoked token should be rejected, got HTTP $REVOKED_CODE"
  fi
fi

# Summary
echo ""
if [ $FAILED -eq 0 ]; then
  ok "PHASE 3 OK"
  exit 0
else
  echo "ERROR verify-phase3: $FAILED check(s) failed" >&2
  exit 1
fi
