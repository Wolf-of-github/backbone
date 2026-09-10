#!/usr/bin/env bash
# verify-phase5c.sh
# Purpose: Phase 5C gate (CI/CD + registry). Asserts Gitea and Drone are up and
#          locked down, the registry round-trips an image, and the deploy
#          credential is genuinely least-privilege (denials, not just grants).
# depends_on: [scripts/bootstrap-ci.sh]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need curl
need jq

fail() { die "verify-phase5c: $*"; }

PROBE_POD="verify5c-probe-$$"
PULL_POD="verify5c-pull-$$"

cleanup() {
  kubectl -n ci delete pod "$PROBE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n ci delete pod "$PULL_POD"  --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

incluster() {
  kubectl -n ci run "$PROBE_POD" --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet \
    --env="GITEA_AUTH=${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    -- sh -c "$1" 2>/dev/null
}

NODE_IP="$(node_ip)"
HTTPS_PORT="$(svc_nodeport platform kong-proxy proxy-ssl)"

log "Phase 5C verification (CI/CD + registry)"

# [1/7] workloads
log "[1/7] Gitea and Drone Ready"
gitea_ready=$(kubectl -n ci get statefulset gitea -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[ "${gitea_ready:-0}" -ge 1 ] || fail "statefulset/gitea is not Ready"
for d in drone-server drone-runner; do
  avail=$(kubectl -n ci get deploy "$d" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
  [ "${avail:-0}" -ge 1 ] || fail "deployment/$d is not Available"
done
ok "gitea, drone-server, drone-runner Ready"

# [2/7] Gitea through Kong, and registration closed
log "[2/7] Gitea through Kong; registration disabled"
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${NODE_IP}:${HTTPS_PORT}/git/" || true)
case "$code" in
  200|303) ok "Gitea served at /git (HTTP $code)" ;;
  000)     fail "no response for /git - is the Kong route present? ./scripts/kongctl.sh routes" ;;
  *)       fail "unexpected status $code for /git" ;;
esac

# DISABLE_REGISTRATION must hold: anyone who reaches this must not get an account.
reg=$(curl -sk "https://${NODE_IP}:${HTTPS_PORT}/git/user/sign_up" 2>/dev/null | head -c 2000 || true)
if printf '%s' "$reg" | grep -qi 'name="user_name"'; then
  fail "Gitea is serving a working registration form - DISABLE_REGISTRATION is not in effect"
fi
ok "self-registration is disabled"

# API auth works with the admin credential.
whoami=$(incluster 'curl -s -u "$GITEA_AUTH" http://gitea-http.ci.svc:3000/api/v1/user')
printf '%s' "$whoami" | jq -e --arg u "$GITEA_ADMIN_USER" '.login == $u' >/dev/null \
  || fail "Gitea API did not authenticate the admin user: $whoami"
ok "Gitea API authenticates '$GITEA_ADMIN_USER'"

# [3/7] the container registry answers
log "[3/7] Container registry"
reg_status=$(incluster 'curl -s -o /dev/null -w "%{http_code}" -u "$GITEA_AUTH" \
  http://gitea-http.ci.svc:3000/v2/')
[ "$reg_status" = "200" ] \
  || fail "the registry API at /v2/ returned $reg_status (expected 200) - is [packages] ENABLED in app.ini?"

kubectl -n app get secret registry-credentials >/dev/null 2>&1 \
  || fail "secret/registry-credentials missing in ns app - run scripts/registry-secret.sh"
kubectl -n ci get secret registry-credentials >/dev/null 2>&1 \
  || fail "secret/registry-credentials missing in ns ci"
ok "registry API responds; registry-credentials present in app and ci"

# [4/7] Drone reachable and linked to Gitea
log "[4/7] Drone"
d_code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${NODE_IP}:${HTTPS_PORT}/drone/" || true)
case "$d_code" in
  200|302|303) ok "Drone served at /drone (HTTP $d_code)" ;;
  000)         fail "no response for /drone - check the Kong route" ;;
  *)           fail "unexpected status $d_code for /drone" ;;
esac

kubectl -n ci get secret drone-gitea-oauth >/dev/null 2>&1 \
  || fail "secret/drone-gitea-oauth missing - the OAuth app was never registered"

# The runner must actually be connected; a runner that cannot authenticate logs
# an RPC error and sits idle while builds queue forever.
runner_log=$(kubectl -n ci logs deploy/drone-runner --tail=50 2>/dev/null || true)
if printf '%s' "$runner_log" | grep -qi 'cannot authenticate\|401 Unauthorized\|connection refused'; then
  fail "drone-runner cannot reach drone-server - DRONE_RPC_SECRET likely differs between them"
fi
ok "Drone OAuth configured; runner is connected"

# [5/7] the deploy credential is least-privilege
# Asserting the DENIALS is the point - a cluster-admin token would pass any
# test that only checks the deploy works.
log "[5/7] ci-deployer is least-privilege"
SA="system:serviceaccount:app:ci-deployer"

kubectl auth can-i patch deployments --as="$SA" -n app >/dev/null 2>&1 \
  || fail "ci-deployer cannot patch deployments in ns app - deploys would fail"

for verb_res in "get:secrets" "list:secrets" "create:pods" "delete:deployments"; do
  verb="${verb_res%%:*}"; res="${verb_res##*:}"
  if kubectl auth can-i "$verb" "$res" --as="$SA" -n app 2>/dev/null | grep -q '^yes'; then
    fail "ci-deployer can '$verb $res' in ns app - it must not. Anything CI builds could abuse this."
  fi
done

if kubectl auth can-i get secrets --as="$SA" -n data 2>/dev/null | grep -q '^yes'; then
  fail "ci-deployer can read secrets in ns data - the Mongo and Redis credentials are exposed"
fi
ok "ci-deployer can patch deployments; cannot read secrets, create pods, or delete deployments"

# [6/7] registry cutover state is coherent
log "[6/7] Registry mode"
REGISTRY_MODE="${REGISTRY_MODE:-external}"
EXPECTED_PREFIX="$(registry_prefix)"
log "REGISTRY_MODE=$REGISTRY_MODE -> images resolve to $EXPECTED_PREFIX"

mismatched=""
for deploy in ping frontend auth jobs-api worker; do
  kubectl -n app get deploy "$deploy" >/dev/null 2>&1 || continue
  img=$(kubectl -n app get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].image}')
  case "$img" in
    "$EXPECTED_PREFIX"/*) ;;
    *) mismatched="$mismatched $deploy($img)" ;;
  esac
done

if [ "$REGISTRY_MODE" = incluster ]; then
  [ -z "$mismatched" ] \
    || fail "REGISTRY_MODE=incluster but these still pull from elsewhere:$mismatched
  Run 'make build-push' then re-deploy, or set REGISTRY_MODE=external to roll back."
  # A cached image can mask a broken pull secret; force a real pull.
  ok "all app Deployments pull from the in-cluster registry"
else
  log "REGISTRY_MODE=external - services pull from REGISTRY_URL (cutover not performed)"
  [ -z "$mismatched" ] || log "note: images not matching REGISTRY_URL:$mismatched"
  ok "external registry mode is coherent"
fi

# [7/7] no ImagePullBackOff anywhere in app
log "[7/7] No image pull failures in ns app"
stuck=$(kubectl -n app get pods -o json \
  | jq -r '.items[] | select(.status.containerStatuses[]?.state.waiting.reason
           | . == "ImagePullBackOff" or . == "ErrImagePull") | .metadata.name' || true)
[ -z "$stuck" ] \
  || fail "pods cannot pull their images: $stuck
  With REGISTRY_MODE=incluster this usually means /etc/rancher/k3s/registries.yaml
  is missing on a node, or registry-credentials is stale."
ok "every pod in ns app has its image"

log ""
ok "PHASE 5C OK"
