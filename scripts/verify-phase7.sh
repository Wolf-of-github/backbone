#!/usr/bin/env bash
# verify-phase7.sh
# Purpose: Verification gate for Phase 7 (cluster dashboard)
# Depends on: bootstrap-dashboard.sh
#
# The seven checks, and why each one earns its place:
#   [1] the workload is actually up
#   [2] RBAC NEGATIVE tests - the dashboard must NOT read secrets. A read-only
#       dashboard that can exfiltrate every credential in the cluster is worse
#       than no dashboard, so this is the check that can fail the gate on its
#       own merits rather than on a wiring mistake.
#   [3] unauthenticated -> 401, non-admin -> 403
#   [4] an admin token gets real data (the node's actual name appears)
#   [5] the WATCH path works end to end - not just the snapshot. A dashboard
#       whose stream is broken looks perfect until something changes.
#   [6] the write actions round-trip against a throwaway Deployment
#   [7] the fail-closed JWT assertion: no public key -> the service must refuse
#       to start. See issues.txt SEC-1.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl curl jq

fail() { die "verify-phase7: $*"; }

SA="system:serviceaccount:app:dashboard-api"
TEST_DEPLOY="phase7-scale-target"
CLEANUP_DONE=0

cleanup() {
  [ "$CLEANUP_DONE" = "1" ] && return
  CLEANUP_DONE=1
  kubectl -n app delete deployment "$TEST_DEPLOY" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Phase 7 verification starting..."

NODE_IP=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | .status.addresses[] | select(.type=="InternalIP" or .type=="ExternalIP") | .address' | head -1)
KONG_PORT=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.spec.ports[0].nodePort}')
ENDPOINT="http://${NODE_IP}:${KONG_PORT}"
log "Testing against endpoint: $ENDPOINT"

# ---------------------------------------------------------------- [1/7] ------
log "[1/7] Workload readiness"
# Polls rather than asserting once: a freshly bootstrapped pod needs a moment
# to establish its first watch, and /healthz is 503 until it does. An immediate
# check cannot tell "still starting" from "broken" - the same lesson as
# verify-phase5b's checks [1] and [4].
DEADLINE=$((SECONDS + 180))
while :; do
  AVAIL=$(kubectl -n app get deployment dashboard-api -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "")
  [ "${AVAIL:-0}" -ge 1 ] 2>/dev/null && break
  [ "$SECONDS" -ge "$DEADLINE" ] && fail "dashboard-api not Available after 180s.
  Inspect: kubectl -n app get pods -l app=dashboard-api
           kubectl -n app logs -l app=dashboard-api --tail=50"
  sleep 5
done
kubectl -n app get svc dashboard-api >/dev/null || fail "dashboard-api Service missing"
kubectl -n app get sa dashboard-api >/dev/null || fail "dashboard-api ServiceAccount missing"
ok "dashboard-api Available, Service and ServiceAccount present"

# ---------------------------------------------------------------- [2/7] ------
log "[2/7] RBAC - positive and negative"

can() { kubectl auth can-i "$@" --as="$SA" 2>/dev/null | tr -d '[:space:]'; }

[ "$(can list pods --all-namespaces)" = "yes" ] || fail "cannot list pods cluster-wide - reads will fail"
[ "$(can list nodes)" = "yes" ]                 || fail "cannot list nodes"
[ "$(can watch pods --all-namespaces)" = "yes" ] || fail "cannot watch pods - the live stream cannot work"
[ "$(can get pods/log -n app)" = "yes" ]        || fail "cannot read pod logs"

# The negatives. These are the point of the check.
[ "$(can get secrets -n data)" = "no" ]       || fail "SECURITY: can read secrets in ns data"
[ "$(can get secrets -n app)" = "no" ]        || fail "SECURITY: can read secrets in ns app"
[ "$(can get secrets -n platform)" = "no" ]   || fail "SECURITY: can read secrets in ns platform"
[ "$(can list secrets --all-namespaces)" = "no" ] || fail "SECURITY: can list secrets cluster-wide"
[ "$(can create pods -n app)" = "no" ]        || fail "SECURITY: can create pods"
[ "$(can create pods/exec -n app)" = "no" ]   || fail "SECURITY: can exec into pods"
# `data` has no write RoleBinding on purpose - deleting mongodb-0 or redis-0 is
# irreversible in a way nothing else this service can do is.
[ "$(can delete pods -n data)" = "no" ]       || fail "SECURITY: can delete pods in ns data"

# And the writes that SHOULD work.
[ "$(can delete pods -n app)" = "yes" ]                 || fail "cannot delete pods in ns app"
[ "$(can patch deployments/scale -n app)" = "yes" ]     || fail "cannot scale deployments in ns app"
[ "$(can patch deployments -n platform)" = "yes" ]      || fail "cannot patch deployments in ns platform"
ok "RBAC correct: cluster reads yes, secrets NO, exec NO, writes scoped to app/platform/observability"

# ---------------------------------------------------------------- [3/7] ------
log "[3/7] Auth gate - 401 unauthenticated, 403 non-admin"

CODE=$(curl -s -o /dev/null -w '%{http_code}' "$ENDPOINT/api/cluster/snapshot")
[ "$CODE" = "401" ] || fail "unauthenticated snapshot returned $CODE, expected 401"

CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer not-a-real-token" "$ENDPOINT/api/cluster/snapshot")
[ "$CODE" = "401" ] || fail "garbage token returned $CODE, expected 401"

# A real, correctly-signed token for a NON-admin user. This is the check that
# would catch a missing requireAdmin on a newly added route.
USER_EMAIL="phase7-user-$(date +%s)@example.com"
USER_PASS="testpass123"
curl -s -X POST "$ENDPOINT/api/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\"}" >/dev/null
USER_TOKEN=$(curl -s -X POST "$ENDPOINT/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASS\"}" | jq -r '.accessToken')
[ -n "$USER_TOKEN" ] && [ "$USER_TOKEN" != "null" ] || fail "could not obtain a non-admin token"

CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $USER_TOKEN" "$ENDPOINT/api/cluster/snapshot")
[ "$CODE" = "403" ] || fail "SECURITY: non-admin got $CODE on snapshot, expected 403"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $USER_TOKEN" "$ENDPOINT/api/cluster/pods/app/nonexistent")
[ "$CODE" = "403" ] || fail "SECURITY: non-admin got $CODE on pod delete, expected 403"
ok "401 for anonymous and bad tokens, 403 for a real non-admin user"

# ---------------------------------------------------------------- [4/7] ------
log "[4/7] Admin snapshot returns real cluster data"

: "${ADMIN_EMAIL:?ADMIN_EMAIL not set in .env - run 'make promote-admin' first}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set in .env - run 'make promote-admin' first}"

ADMIN_TOKEN=$(curl -s -X POST "$ENDPOINT/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | jq -r '.accessToken')
[ -n "$ADMIN_TOKEN" ] && [ "$ADMIN_TOKEN" != "null" ] \
  || fail "admin login failed for $ADMIN_EMAIL - check ADMIN_PASSWORD in .env"

SNAP=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "$ENDPOINT/api/cluster/snapshot")
REAL_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

# Asserting the REAL node name appears, not merely that the shape is right:
# an endpoint returning well-formed empty arrays would pass a shape check while
# showing the operator nothing.
echo "$SNAP" | jq -e --arg n "$REAL_NODE" '.items.nodes[] | select(.name == $n)' >/dev/null \
  || fail "snapshot does not contain the real node '$REAL_NODE'"

POD_COUNT=$(echo "$SNAP" | jq '.items.pods | length')
[ "$POD_COUNT" -gt 0 ] || fail "snapshot reported zero pods"
echo "$SNAP" | jq -e '.resourceVersions.pods' >/dev/null \
  || fail "snapshot missing resourceVersions - the stream cannot resume without them"
ok "snapshot: node '$REAL_NODE' present, $POD_COUNT pods, resourceVersions included"

# ---------------------------------------------------------------- [5/7] ------
log "[5/7] Watch stream delivers a live event"

# A snapshot can work perfectly while the watch layer is broken; the UI then
# renders once and silently goes stale. Forcing a real change and requiring it
# to arrive on the stream is the only way to tell the difference.
STREAM_OUT=$(mktemp)
curl -sN --max-time 45 -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$ENDPOINT/api/cluster/stream" > "$STREAM_OUT" 2>/dev/null &
STREAM_PID=$!
sleep 5

kubectl -n app create deployment "$TEST_DEPLOY" --image=busybox:1.36 \
  -- sh -c 'sleep 3600' >/dev/null 2>&1 || fail "could not create the test Deployment"

# Poll for the event rather than sleeping a fixed amount: scheduling latency
# varies, and a fixed sleep is either flaky or needlessly slow.
FOUND=0
for _ in $(seq 1 30); do
  if grep -q "$TEST_DEPLOY" "$STREAM_OUT" 2>/dev/null; then FOUND=1; break; fi
  sleep 1
done

kill "$STREAM_PID" 2>/dev/null || true
wait "$STREAM_PID" 2>/dev/null || true

grep -q 'event: hello' "$STREAM_OUT" || fail "stream never sent its hello frame - SSE is not reaching the client.
  If the snapshot works but this does not, suspect Kong buffering the response:
  check read_timeout and that the route reaches dashboard-api."
[ "$FOUND" = "1" ] || fail "created $TEST_DEPLOY but no event for it arrived on the stream within 30s.
  The snapshot path works and the watch path does not - the dashboard will
  render once and then silently go stale.
  Inspect: kubectl -n app logs -l app=dashboard-api --tail=50"
rm -f "$STREAM_OUT"
ok "stream sent hello and delivered a live event for a newly created workload"

# ---------------------------------------------------------------- [6/7] ------
log "[6/7] Write actions round-trip"

kubectl -n app rollout status "deploy/$TEST_DEPLOY" --timeout=90s >/dev/null 2>&1 || true

# scale 1 -> 2
CODE=$(curl -s -o /tmp/p7scale.json -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"replicas":2}' \
  "$ENDPOINT/api/cluster/deployments/app/$TEST_DEPLOY/scale")
[ "$CODE" = "200" ] || fail "scale returned $CODE: $(cat /tmp/p7scale.json)"
for _ in $(seq 1 20); do
  SPEC=$(kubectl -n app get deploy "$TEST_DEPLOY" -o jsonpath='{.spec.replicas}')
  [ "$SPEC" = "2" ] && break
  sleep 1
done
[ "$SPEC" = "2" ] || fail "API reported success but spec.replicas is $SPEC, expected 2"
# The audit log records the previous value, which is what makes it useful.
jq -e '.from == 1 and .to == 2' /tmp/p7scale.json >/dev/null \
  || fail "scale response did not report from/to correctly: $(cat /tmp/p7scale.json)"

# scale to 0 - permitted by explicit operator decision (issues.txt AVAIL-2),
# so the gate asserts it works rather than that it is blocked.
curl -s -o /dev/null -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' -d '{"replicas":0}' \
  "$ENDPOINT/api/cluster/deployments/app/$TEST_DEPLOY/scale"
for _ in $(seq 1 20); do
  SPEC=$(kubectl -n app get deploy "$TEST_DEPLOY" -o jsonpath='{.spec.replicas}')
  [ "$SPEC" = "0" ] && break
  sleep 1
done
[ "$SPEC" = "0" ] || fail "scale-to-zero did not apply (spec.replicas=$SPEC)"

# rejected input
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"replicas":-1}' "$ENDPOINT/api/cluster/deployments/app/$TEST_DEPLOY/scale")
[ "$CODE" = "400" ] || fail "negative replicas returned $CODE, expected 400"

# restart
curl -s -o /dev/null -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' -d '{"replicas":1}' \
  "$ENDPOINT/api/cluster/deployments/app/$TEST_DEPLOY/scale"
kubectl -n app rollout status "deploy/$TEST_DEPLOY" --timeout=90s >/dev/null 2>&1 || true
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$ENDPOINT/api/cluster/deployments/app/$TEST_DEPLOY/restart")
[ "$CODE" = "200" ] || fail "restart returned $CODE, expected 200"
kubectl -n app get deploy "$TEST_DEPLOY" \
  -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}' \
  | grep -q . || fail "restart did not set the restartedAt annotation"

# pod delete
POD=$(kubectl -n app get pods -l "app=$TEST_DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$POD" ]; then
  CODE=$(curl -s -o /tmp/p7del.json -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $ADMIN_TOKEN" "$ENDPOINT/api/cluster/pods/app/$POD")
  [ "$CODE" = "200" ] || fail "pod delete returned $CODE: $(cat /tmp/p7del.json)"
  # replaced:true is what tells an operator this was a restart, not a removal.
  jq -e '.replaced == true' /tmp/p7del.json >/dev/null \
    || fail "delete of a controller-managed pod did not report replaced:true"
fi

# RBAC must refuse the data namespace even though the API would otherwise try.
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
  -H "Authorization: Bearer $ADMIN_TOKEN" "$ENDPOINT/api/cluster/pods/data/mongodb-0")
[ "$CODE" = "403" ] || fail "SECURITY: deleting a pod in ns data returned $CODE, expected 403"

rm -f /tmp/p7scale.json /tmp/p7del.json
ok "scale (incl. zero), input rejection, restart, pod delete all round-trip; ns data refused"

# ---------------------------------------------------------------- [7/7] ------
log "[7/7] Fail-closed on a missing JWT public key"

# The service must refuse to start without its signing key, because the
# alternative - serving an admin API that verifies nothing - is the failure
# mode issues.txt SEC-1 describes. Tested in a throwaway pod with the key path
# pointed at nothing, rather than by breaking the running Deployment.
IMAGE=$(kubectl -n app get deploy dashboard-api -o jsonpath='{.spec.template.spec.containers[0].image}')
kubectl -n app delete pod phase7-failclosed --ignore-not-found >/dev/null 2>&1 || true
kubectl -n app run phase7-failclosed --image="$IMAGE" --restart=Never \
  --env="JWT_PUBLIC_KEY_PATH=/nonexistent/key" --command -- node src/index.js >/dev/null 2>&1

FAILED_CLOSED=0
for _ in $(seq 1 30); do
  PHASE=$(kubectl -n app get pod phase7-failclosed -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$PHASE" = "Failed" ]; then FAILED_CLOSED=1; break; fi
  if [ "$PHASE" = "Running" ]; then
    sleep 3
    PHASE=$(kubectl -n app get pod phase7-failclosed -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "$PHASE" = "Failed" ] && { FAILED_CLOSED=1; break; }
  fi
  sleep 2
done

LOGS=$(kubectl -n app logs phase7-failclosed 2>/dev/null || echo "")
kubectl -n app delete pod phase7-failclosed --ignore-not-found --wait=false >/dev/null 2>&1 || true

[ "$FAILED_CLOSED" = "1" ] \
  || fail "SECURITY: dashboard-api STARTED without a JWT public key. It must exit non-zero.
  Pod phase was '$PHASE'. See services/dashboard-api/src/auth.js and issues.txt SEC-1."
echo "$LOGS" | grep -qi "JWT public key" \
  || log "  note: exited as required, but without the expected key-path message"
ok "service refuses to start without its JWT public key"

cleanup
log ""
ok "PHASE 7 OK"
