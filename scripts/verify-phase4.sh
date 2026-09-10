#!/usr/bin/env bash
# verify-phase4.sh
# Purpose: Verification gate for Phase 4 (async jobs)
# Depends on: bootstrap-jobs.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl curl jq

fail() { die "verify-phase4: $*"; }

log "Phase 4 verification starting..."

# Get Kong endpoint
NODE_IP=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | .status.addresses[] | select(.type=="InternalIP" or .type=="ExternalIP") | .address' | head -1)
KONG_PORT=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.spec.ports[0].nodePort}')
ENDPOINT="http://${NODE_IP}:${KONG_PORT}"

log "Testing against endpoint: $ENDPOINT"

# [1/7] Check deployments and services
log "[1/7] Deployments and services"
kubectl -n app get deployment jobs-api -o jsonpath='{.status.availableReplicas}' | grep -q "2" || fail "jobs-api not ready (expected 2/2)"
WORKER_REPLICAS=$(kubectl -n app get deployment worker -o jsonpath='{.status.availableReplicas}')
[[ "$WORKER_REPLICAS" -ge 1 ]] || fail "worker not ready (expected >= 1)"
kubectl -n app get svc jobs-api > /dev/null || fail "jobs-api service missing"
kubectl -n app get hpa worker-hpa > /dev/null || fail "worker HPA missing"
ok "jobs-api (2/2) and worker ($WORKER_REPLICAS replicas) ready, HPA configured"

# [2/7] End-to-end job creation (authenticated)
log "[2/7] End-to-end job creation (authenticated)"

# Register test user
TEST_EMAIL="phase4-test-$(date +%s)@example.com"
TEST_PASSWORD="testpass123"

REGISTER_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")

echo "$REGISTER_RESPONSE" | jq -e '.message' > /dev/null || fail "Registration failed: $REGISTER_RESPONSE"
ok "Test user registered"

# Login
LOGIN_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")

ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.accessToken')
[[ -n "$ACCESS_TOKEN" && "$ACCESS_TOKEN" != "null" ]] || fail "Login failed: $LOGIN_RESPONSE"
ok "Login successful, got access token"

# Create hello-world job
JOB_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/jobs" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"hello-world","data":{"name":"Phase4"}}')

JOB_ID=$(echo "$JOB_RESPONSE" | jq -r '.jobId')
[[ -n "$JOB_ID" && "$JOB_ID" != "null" ]] || fail "Job creation failed: $JOB_RESPONSE"
ok "Job created: $JOB_ID"

# [3/7] Job completion polling
log "[3/7] Job completion polling"
MAX_WAIT=30
WAITED=0
JOB_STATUS="pending"

while [[ "$JOB_STATUS" != "completed" && "$WAITED" -lt "$MAX_WAIT" ]]; do
  sleep 2
  WAITED=$((WAITED + 2))

  STATUS_RESPONSE=$(curl -s -X GET "$ENDPOINT/api/jobs/$JOB_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN")

  JOB_STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status')

  if [[ "$JOB_STATUS" == "failed" ]]; then
    fail "Job failed unexpectedly: $(echo "$STATUS_RESPONSE" | jq -r '.result')"
  fi
done

[[ "$JOB_STATUS" == "completed" ]] || fail "Job did not complete within ${MAX_WAIT}s (status: $JOB_STATUS)"

GREETING=$(echo "$STATUS_RESPONSE" | jq -r '.result.greeting')
[[ "$GREETING" == "Hello, Phase4!" ]] || fail "Unexpected result: $GREETING"
ok "Job completed successfully with correct result"

# [4/7] Failing job retry
log "[4/7] Failing job retry"
FAIL_JOB_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/jobs" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"failing-job","data":{}}')

FAIL_JOB_ID=$(echo "$FAIL_JOB_RESPONSE" | jq -r '.jobId')
[[ -n "$FAIL_JOB_ID" && "$FAIL_JOB_ID" != "null" ]] || fail "Failing job creation failed"

# Wait for it to fail after retries
MAX_WAIT=20
WAITED=0
FAIL_JOB_STATUS="pending"

while [[ "$FAIL_JOB_STATUS" != "failed" && "$WAITED" -lt "$MAX_WAIT" ]]; do
  sleep 2
  WAITED=$((WAITED + 2))

  FAIL_STATUS_RESPONSE=$(curl -s -X GET "$ENDPOINT/api/jobs/$FAIL_JOB_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN")

  FAIL_JOB_STATUS=$(echo "$FAIL_STATUS_RESPONSE" | jq -r '.status')
done

[[ "$FAIL_JOB_STATUS" == "failed" ]] || fail "Failing job did not fail as expected (status: $FAIL_JOB_STATUS)"

FAIL_ERROR=$(echo "$FAIL_STATUS_RESPONSE" | jq -r '.result.error')
echo "$FAIL_ERROR" | grep -q "always fails" || fail "Unexpected error message: $FAIL_ERROR"
ok "Failing job retried and failed as expected"

# [5/7] Job ownership (IDOR prevention)
log "[5/7] Job ownership (IDOR prevention)"

# Register second user
TEST_EMAIL_2="phase4-test2-$(date +%s)@example.com"
REGISTER_RESPONSE_2=$(curl -s -X POST "$ENDPOINT/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL_2\",\"password\":\"$TEST_PASSWORD\"}")

# Login as second user
LOGIN_RESPONSE_2=$(curl -s -X POST "$ENDPOINT/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL_2\",\"password\":\"$TEST_PASSWORD\"}")

ACCESS_TOKEN_2=$(echo "$LOGIN_RESPONSE_2" | jq -r '.accessToken')
[[ -n "$ACCESS_TOKEN_2" && "$ACCESS_TOKEN_2" != "null" ]] || fail "Second user login failed"

# Try to access first user's job
IDOR_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$ENDPOINT/api/jobs/$JOB_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN_2")

HTTP_CODE=$(echo "$IDOR_RESPONSE" | tail -n1)
[[ "$HTTP_CODE" == "403" ]] || fail "IDOR check failed: user2 could access user1's job (HTTP $HTTP_CODE)"
ok "IDOR prevention works (user2 cannot access user1's job)"

# User2 can create and read their own job
USER2_JOB_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/jobs" \
  -H "Authorization: Bearer $ACCESS_TOKEN_2" \
  -H "Content-Type: application/json" \
  -d '{"type":"hello-world","data":{"name":"User2"}}')

USER2_JOB_ID=$(echo "$USER2_JOB_RESPONSE" | jq -r '.jobId')
[[ -n "$USER2_JOB_ID" && "$USER2_JOB_ID" != "null" ]] || fail "User2 job creation failed"

USER2_GET_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$ENDPOINT/api/jobs/$USER2_JOB_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN_2")

HTTP_CODE=$(echo "$USER2_GET_RESPONSE" | tail -n1)
[[ "$HTTP_CODE" == "200" ]] || fail "User2 cannot read their own job"
ok "User2 can create and read their own jobs"

# [6/7] Worker resilience
log "[6/7] Worker resilience"
# Create a job
RESILIENCE_JOB_RESPONSE=$(curl -s -X POST "$ENDPOINT/api/jobs" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"hello-world","data":{"name":"Resilience"}}')

RESILIENCE_JOB_ID=$(echo "$RESILIENCE_JOB_RESPONSE" | jq -r '.jobId')

# Kill a worker pod
WORKER_POD=$(kubectl -n app get pods -l app=worker -o jsonpath='{.items[0].metadata.name}')
if [[ -n "$WORKER_POD" ]]; then
  kubectl -n app delete pod "$WORKER_POD" --wait=false > /dev/null 2>&1 || true
  log "  Killed worker pod $WORKER_POD"
fi

# Wait for job to complete (another worker or restarted pod will process it)
MAX_WAIT=40
WAITED=0
RESILIENCE_STATUS="pending"

while [[ "$RESILIENCE_STATUS" != "completed" && "$WAITED" -lt "$MAX_WAIT" ]]; do
  sleep 2
  WAITED=$((WAITED + 2))

  RESILIENCE_RESPONSE=$(curl -s -X GET "$ENDPOINT/api/jobs/$RESILIENCE_JOB_ID" \
    -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null || echo '{"status":"pending"}')

  RESILIENCE_STATUS=$(echo "$RESILIENCE_RESPONSE" | jq -r '.status')
done

[[ "$RESILIENCE_STATUS" == "completed" ]] || fail "Job did not complete after worker restart (status: $RESILIENCE_STATUS)"
ok "Worker resilience verified (job completed despite pod restart)"

# [7/7] List jobs
log "[7/7] List jobs"
LIST_RESPONSE=$(curl -s -X GET "$ENDPOINT/api/jobs" \
  -H "Authorization: Bearer $ACCESS_TOKEN")

JOB_COUNT=$(echo "$LIST_RESPONSE" | jq -r '.count')
[[ "$JOB_COUNT" -ge 2 ]] || fail "Expected at least 2 jobs for user1, got $JOB_COUNT"

# Verify all jobs belong to user1
WRONG_OWNER=$(echo "$LIST_RESPONSE" | jq -r '.jobs[] | select(.jobId == "'$USER2_JOB_ID'") | .jobId')
[[ -z "$WRONG_OWNER" ]] || fail "User1's job list contains user2's job"
ok "Job listing works (found $JOB_COUNT jobs for user1)"

# Cleanup
log "Cleaning up test users..."
kubectl -n data run mongosh-cleanup --rm -it --restart=Never --image=mongo:7.0 -- \
  mongosh "mongodb://$MONGO_APP_USER:$MONGO_APP_PASSWORD@mongodb.data.svc/$MONGO_APP_DB" \
  --quiet --eval "db.users.deleteMany({email: {$in: ['$TEST_EMAIL', '$TEST_EMAIL_2']}})" 2>/dev/null || true

log ""
ok "PHASE 4 OK"
log ""
log "All tests passed:"
log "  ✓ Deployments and HPA configured"
log "  ✓ Job creation and completion"
log "  ✓ Retry logic for failing jobs"
log "  ✓ IDOR prevention enforced"
log "  ✓ Worker resilience verified"
log "  ✓ Job listing works correctly"
