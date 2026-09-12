#!/usr/bin/env bash
# verify-notes.sh
# Purpose: Verification gate for the Notes CRUD demo (notes-api + notes-worker)
# Depends on: bootstrap-notes.sh
# Modeled on verify-phase4.sh's shape - same auth flow, same IDOR check.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl curl jq

fail() { die "verify-notes: $*"; }

log "Notes demo verification starting..."

NODE_IP=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | .status.addresses[] | select(.type=="InternalIP" or .type=="ExternalIP") | .address' | head -1)
KONG_PORT=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.spec.ports[0].nodePort}')
ENDPOINT="http://${NODE_IP}:${KONG_PORT}"

log "Testing against endpoint: $ENDPOINT"

# [1/6] Deployments and services
log "[1/6] Deployments and services"
kubectl -n app get deployment notes-api -o jsonpath='{.status.availableReplicas}' | grep -q "2" || fail "notes-api not ready (expected 2/2)"
WORKER_REPLICAS=$(kubectl -n app get deployment notes-worker -o jsonpath='{.status.availableReplicas}')
[[ "$WORKER_REPLICAS" -ge 1 ]] || fail "notes-worker not ready (expected >= 1)"
kubectl -n app get svc notes-api > /dev/null || fail "notes-api service missing"
ok "notes-api (2/2) and notes-worker ($WORKER_REPLICAS replicas) ready"

# [2/6] Auth (reuses the existing auth service - no auth of its own here)
log "[2/6] Registering and logging in a test user"
TEST_EMAIL="notes-test-$(date +%s)@example.com"
TEST_PASSWORD="testpass123"

REGISTER_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")
echo "$REGISTER_RESPONSE" | jq -e '.message' > /dev/null || fail "Registration failed: $REGISTER_RESPONSE"

LOGIN_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")
ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.accessToken')
[[ -n "$ACCESS_TOKEN" && "$ACCESS_TOKEN" != "null" ]] || fail "Login failed: $LOGIN_RESPONSE"
ok "Test user registered and logged in"

# [3/6] Unauthenticated request rejected
log "[3/6] Unauthenticated request is rejected"
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT/api/notes" \
  -H "Content-Type: application/json" -d '{"title":"nope"}')
[[ "$UNAUTH_CODE" == "401" ]] || fail "Expected 401 with no token, got $UNAUTH_CODE"
ok "Unauthenticated create correctly rejected (401)"

# [4/6] Create a note - proves the async path end to end
log "[4/6] Create note (async - enqueue, poll, confirm write)"
CREATE_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/notes" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"verify-notes","body":"created by the verification gate"}')

[[ "$(echo "$CREATE_RESPONSE" | jq -r '.status')" == "queued" ]] || fail "Create did not return queued: $CREATE_RESPONSE"
PENDING_ID=$(echo "$CREATE_RESPONSE" | jq -r '.pendingId')
[[ -n "$PENDING_ID" && "$PENDING_ID" != "null" ]] || fail "No pendingId returned: $CREATE_RESPONSE"
ok "Create enqueued: $PENDING_ID"

MAX_WAIT=20
WAITED=0
NOTE_STATUS="pending"
while [[ "$NOTE_STATUS" != "completed" && "$WAITED" -lt "$MAX_WAIT" ]]; do
  sleep 2
  WAITED=$((WAITED + 2))
  STATUS_RESPONSE=$(curl -s -X GET "$ENDPOINT/api/notes/$PENDING_ID" -H "Authorization: Bearer $ACCESS_TOKEN")
  NOTE_STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status')
done
[[ "$NOTE_STATUS" == "completed" ]] || fail "Note did not complete within ${MAX_WAIT}s (status: $NOTE_STATUS) - check: kubectl -n app logs -l app=notes-worker"

TITLE=$(echo "$STATUS_RESPONSE" | jq -r '.title')
[[ "$TITLE" == "verify-notes" ]] || fail "Unexpected title after processing: $TITLE"
ok "notes-worker processed the job; note is completed in MongoDB"

# [5/6] Ownership (IDOR prevention)
log "[5/6] Ownership (IDOR prevention)"
TEST_EMAIL_2="notes-test2-$(date +%s)@example.com"
curl -s -X POST "$ENDPOINT/api/auth/register" -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL_2\",\"password\":\"$TEST_PASSWORD\"}" > /dev/null

LOGIN_RESPONSE_2=$(curl -s -X POST "$ENDPOINT/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL_2\",\"password\":\"$TEST_PASSWORD\"}")
ACCESS_TOKEN_2=$(echo "$LOGIN_RESPONSE_2" | jq -r '.accessToken')
[[ -n "$ACCESS_TOKEN_2" && "$ACCESS_TOKEN_2" != "null" ]] || fail "Second user login failed"

IDOR_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$ENDPOINT/api/notes/$PENDING_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN_2")
[[ "$IDOR_CODE" == "403" ]] || fail "IDOR check failed: user2 could access user1's note (HTTP $IDOR_CODE)"
ok "IDOR prevention works (user2 cannot access user1's note)"

# [6/6] List notes
log "[6/6] List notes"
LIST_RESPONSE=$(curl -s -X GET "$ENDPOINT/api/notes" -H "Authorization: Bearer $ACCESS_TOKEN")
NOTE_COUNT=$(echo "$LIST_RESPONSE" | jq '.notes | length')
[[ "$NOTE_COUNT" -ge 1 ]] || fail "Expected at least 1 note for user1, got $NOTE_COUNT"
ok "Listing works (found $NOTE_COUNT note(s) for user1)"

# Cleanup
log "Cleaning up test users and notes..."
MONGO_URI_CLEANUP="mongodb://$(urlencode "$MONGO_APP_USER"):$(urlencode "$MONGO_APP_PASSWORD")@mongodb.data.svc/$MONGO_APP_DB"
kubectl -n data run mongosh-cleanup-notes --rm -i --restart=Never --image=mongo:7.0 -- \
  mongosh "$MONGO_URI_CLEANUP" --quiet \
  --eval "db.users.deleteMany({email: {\$in: ['$TEST_EMAIL', '$TEST_EMAIL_2']}}); db.notes.deleteMany({pendingId: '$PENDING_ID'})" \
  2>/dev/null || true

log ""
ok "NOTES DEMO OK"
log ""
log "All checks passed:"
log "  - notes-api and notes-worker deployments ready"
log "  - unauthenticated create rejected"
log "  - create -> enqueue -> notes-worker processes -> MongoDB write, end to end"
log "  - IDOR prevention enforced"
log "  - listing works"
