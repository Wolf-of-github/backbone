#!/usr/bin/env bash
# Phase 1 acceptance gate. Exits non-zero on the first failed assertion.
# depends_on: [scripts/bootstrap-data.sh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars \
  MONGO_APP_USER MONGO_APP_PASSWORD MONGO_APP_DB \
  REDIS_PASSWORD
need kubectl

fail() { die "verify-phase1: $*"; }

RUN="verify-phase1-$$"
N=0
cleanup() {
  kubectl -n data delete pod -l "run=$RUN" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# run_in_pod <image> -- reads a shell script on stdin, runs it in a throwaway
# pod in the data namespace, prints its stdout. Env for the script is passed
# through the calling shell's environment via `--env`.
run_in_pod() {
  local image="$1"
  N=$((N + 1))
  kubectl -n data run "${RUN}-${N}" \
    --labels="run=$RUN" --image="$image" --restart=Never \
    --stdin --rm --quiet --pod-running-timeout=120s \
    --env="REDIS_PASSWORD=$REDIS_PASSWORD" \
    --env="MONGO_URI=$MONGO_URI" \
    --env="MONGO_APP_DB=$MONGO_APP_DB" \
    --env="RUN=$RUN" \
    --command -- sh -s
}

MONGO_URI="mongodb://$(urlencode "$MONGO_APP_USER"):$(urlencode "$MONGO_APP_PASSWORD")@mongodb.data.svc:27017/${MONGO_APP_DB}"

# 1. Both StatefulSets Ready (1/1).
log "[1/6] StatefulSets Ready"
kubectl -n data rollout status statefulset/redis   --timeout=60s >/dev/null || fail "redis not Ready"
kubectl -n data rollout status statefulset/mongodb --timeout=60s >/dev/null || fail "mongodb not Ready"
ok "redis and mongodb StatefulSets Ready (1/1)"

# 2. Secrets present with the expected keys (keys only, never values).
log "[2/6] secrets"
mc_keys="$(kubectl -n data get secret mongodb-credentials -o jsonpath='{.data}' 2>/dev/null)" \
  || fail "secret mongodb-credentials missing"
for k in root-username root-password app-username app-password app-db; do
  printf '%s' "$mc_keys" | grep -q "\"$k\"" || fail "mongodb-credentials missing key '$k'"
done
kubectl -n data get secret redis-password -o jsonpath='{.data.password}' 2>/dev/null | grep -q . \
  || fail "secret redis-password missing key 'password'"
ok "mongodb-credentials (5 keys) and redis-password (1 key) present"

# 3. PVCs Bound.
log "[3/6] PVCs Bound"
for pvc in data-redis-0 data-mongodb-0; do
  phase="$(kubectl -n data get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = "Bound" ] || fail "PVC $pvc is '${phase:-missing}', expected Bound"
done
ok "data-redis-0 and data-mongodb-0 Bound"

# 4. Redis round-trip + AUTH enforced.
log "[4/6] Redis auth + round-trip"
out="$(run_in_pod redis:7.2-alpine <<'EOF'
set -e
R="redis-cli -h redis.data.svc"
# a) no AUTH must be refused
$R GET nope 2>&1 | grep -q NOAUTH && echo NOAUTH_OK || echo NOAUTH_BAD
# b) authed round-trip
$R -a "$REDIS_PASSWORD" --no-auth-warning SET "$RUN" hello >/dev/null
$R -a "$REDIS_PASSWORD" --no-auth-warning GET "$RUN"
$R -a "$REDIS_PASSWORD" --no-auth-warning DEL "$RUN" >/dev/null
EOF
)"
printf '%s\n' "$out" | grep -q NOAUTH_OK || fail "Redis accepted a command without AUTH"
printf '%s\n' "$out" | grep -qx hello    || fail "Redis SET/GET round-trip failed"
ok "Redis requires AUTH; SET/GET/DEL round-trip works"

# 5. MongoDB round-trip as the app user + least-privilege holds.
#    Note: `listDatabases` is NOT a valid probe - MongoDB silently returns an
#    empty list (authorizedDatabases fallback) rather than erroring. Use a write
#    to a DB the user has no role on, and a user-admin op; both must be denied.
log "[5/6] MongoDB app-user round-trip + least-privilege"
out="$(run_in_pod mongo:7.0 <<'EOF'
set -e
run() { mongosh "$MONGO_URI" --quiet --eval "$1"; }
run "db.verify.insertOne({ k: '$RUN' })" >/dev/null
run "print(db.verify.findOne({ k: '$RUN' }).k)"
run "db.verify.drop()" >/dev/null

# a) authenticated as the app user, scoped to the app DB?
run "const a = db.runCommand({connectionStatus:1}).authInfo.authenticatedUserRoles;
     if (a.length === 1 && a[0].role === 'readWrite' && a[0].db === '$MONGO_APP_DB') print('AUTH_OK');
     else print('AUTH_BAD ' + JSON.stringify(a));"

# b) writing to another database MUST be denied
run "try { db.getSiblingDB('admin').x.insertOne({y:1}); print('WRITE_BAD'); }
     catch (e) { print(e.codeName === 'Unauthorized' ? 'WRITE_DENIED_OK' : 'WRITE_ERR ' + e.codeName); }"

# c) a user-admin op MUST be denied (any throw = denied; success = privilege escalation)
run "try { db.getSiblingDB('$MONGO_APP_DB').createUser({user:'x$RUN',pwd:'xxxxxxxx',roles:[]}); print('ADMIN_BAD'); }
     catch (e) { print(/not authorized|unauthorized/i.test(e.message) ? 'ADMIN_DENIED_OK' : 'ADMIN_ERR ' + e.message); }"
EOF
)"
printf '%s\n' "$out" | grep -qx "$RUN"           || fail "MongoDB app-user insert/read/drop failed"
printf '%s\n' "$out" | grep -q AUTH_OK           || fail "app user not authenticated as readWrite@${MONGO_APP_DB}: $out"
printf '%s\n' "$out" | grep -q WRITE_DENIED_OK   || fail "app user could write outside ${MONGO_APP_DB} (not least-privilege): $out"
printf '%s\n' "$out" | grep -q ADMIN_DENIED_OK   || fail "app user could run a user-admin op (not least-privilege): $out"
ok "app user does I/O on ${MONGO_APP_DB}; cross-DB writes and admin ops denied"

# 6. Persistence across a pod delete.
log "[6/6] data survives a pod restart"
run_in_pod redis:7.2-alpine >/dev/null <<'EOF'
redis-cli -h redis.data.svc -a "$REDIS_PASSWORD" --no-auth-warning SET "$RUN-persist" survived EX 600 >/dev/null
EOF
run_in_pod mongo:7.0 >/dev/null <<'EOF'
mongosh "$MONGO_URI" --quiet --eval "db.persist.insertOne({ k: '$RUN' })" >/dev/null
EOF

kubectl -n data delete pod redis-0 mongodb-0 --wait=true >/dev/null
kubectl -n data rollout status statefulset/redis   --timeout=120s >/dev/null || fail "redis did not come back"
kubectl -n data rollout status statefulset/mongodb --timeout=180s >/dev/null || fail "mongodb did not come back"

rv="$(run_in_pod redis:7.2-alpine <<'EOF'
redis-cli -h redis.data.svc -a "$REDIS_PASSWORD" --no-auth-warning GET "$RUN-persist"
EOF
)"
printf '%s\n' "$rv" | grep -qx survived || fail "Redis lost data across a pod restart"

mv="$(run_in_pod mongo:7.0 <<'EOF'
mongosh "$MONGO_URI" --quiet --eval "print(db.persist.findOne({ k: '$RUN' }).k)"
EOF
)"
printf '%s\n' "$mv" | grep -qx "$RUN" || fail "MongoDB lost data across a pod restart"

# tidy the persistence probe collection
run_in_pod mongo:7.0 >/dev/null <<'EOF' || true
mongosh "$MONGO_URI" --quiet --eval "db.persist.drop()" >/dev/null
EOF
ok "Redis and MongoDB data survived deleting their pods"

printf '\n\033[32mPHASE 1 OK\033[0m\n' >&2
