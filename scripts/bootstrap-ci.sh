#!/usr/bin/env bash
# bootstrap-ci.sh
# Purpose: Phase 5C - Gitea (git + container registry) and Drone (CI), wired
#          together automatically including the OAuth app registration.
# depends_on: [scripts/gitea-secrets.sh, scripts/deploy-key.sh,
#              scripts/registry-secret.sh, k8s/ci/**, scripts/lib.sh]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need jq
need envsubst

RENDER_DIR="$REPO_ROOT/.rendered/ci"
CI_DIR="k8s/ci"
HELPER_POD="ci-bootstrap-$$"

cleanup() {
  kubectl -n ci delete pod "$HELPER_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl get ns ci >/dev/null 2>&1 \
  || die "namespace 'ci' missing - run 'make base' first"

require_vars GITEA_ADMIN_USER GITEA_ADMIN_PASSWORD GITEA_ADMIN_EMAIL DRONE_RPC_SECRET

mkdir -p "$RENDER_DIR"

HTTPS_PORT="$(svc_nodeport platform kong-proxy proxy-ssl 2>/dev/null || echo 30443)"
HOST="$(platform_host)"

if has_real_domain; then
  PUBLIC_BASE="https://${HOST}"
else
  PUBLIC_BASE="https://${HOST}:${HTTPS_PORT}"
fi

# ---------------------------------------------------------------------------
# 1. Secrets
# ---------------------------------------------------------------------------
"$REPO_ROOT/scripts/gitea-secrets.sh"

# ---------------------------------------------------------------------------
# 2. Gitea
# ---------------------------------------------------------------------------
log "Applying Gitea..."
GITEA_ROOT_URL="${PUBLIC_BASE}/git/"
GITEA_DOMAIN="$HOST"
export GITEA_ROOT_URL GITEA_DOMAIN

render_template "$CI_DIR/gitea/configmap.yaml" "$RENDER_DIR/gitea-config.yaml" \
  'GITEA_ROOT_URL GITEA_DOMAIN'
kubectl apply -f "$RENDER_DIR/gitea-config.yaml"
kubectl apply -f "$CI_DIR/gitea/statefulset.yaml"
kubectl apply -f "$CI_DIR/gitea/service.yaml"

kubectl -n ci rollout status statefulset/gitea --timeout=300s \
  || die "Gitea did not become Ready. Check: kubectl -n ci logs statefulset/gitea"
ok "Gitea Ready"

# ---------------------------------------------------------------------------
# 3. Admin account. INSTALL_LOCK skips the setup wizard, so the first admin must
#    be created with the CLI inside the pod.
# ---------------------------------------------------------------------------
log "Ensuring the Gitea admin account exists..."
if kubectl -n ci exec statefulset/gitea -- \
     gitea admin user list 2>/dev/null | grep -q "$GITEA_ADMIN_USER"; then
  log "admin '$GITEA_ADMIN_USER' already exists"
else
  # Password passed via env, not on the command line - process args are visible
  # to anything that can read /proc in the container.
  kubectl -n ci exec statefulset/gitea -- env \
    GITEA_ADMIN_PW="$GITEA_ADMIN_PASSWORD" \
    sh -c 'gitea admin user create \
      --username "$0" --email "$1" \
      --password "$GITEA_ADMIN_PW" --admin --must-change-password=false' \
    "$GITEA_ADMIN_USER" "$GITEA_ADMIN_EMAIL" \
    || die "could not create the Gitea admin account"
  ok "admin '$GITEA_ADMIN_USER' created"
fi

# ---------------------------------------------------------------------------
# 4. OAuth app for Drone.
#    Registering this through the API rather than the UI is what keeps the
#    phase reproducible - the usual instructions have you click through Gitea.
# ---------------------------------------------------------------------------
log "Registering the Drone OAuth application in Gitea..."

gitea_api() {
  local method="$1" path="$2" body="${3:-}"
  kubectl -n ci run "$HELPER_POD" --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet \
    --env="GITEA_AUTH=${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    --env="REQ_METHOD=$method" --env="REQ_PATH=$path" --env="REQ_BODY=$body" \
    -- sh -c '
      if [ -n "$REQ_BODY" ]; then
        curl -s -X "$REQ_METHOD" -u "$GITEA_AUTH" -H "Content-Type: application/json" \
          -d "$REQ_BODY" "http://gitea-http.ci.svc:3000/api/v1$REQ_PATH"
      else
        curl -s -X "$REQ_METHOD" -u "$GITEA_AUTH" -H "Content-Type: application/json" \
          "http://gitea-http.ci.svc:3000/api/v1$REQ_PATH"
      fi
    ' 2>/dev/null
}

DRONE_REDIRECT="${PUBLIC_BASE}/drone/login"

if kubectl -n ci get secret drone-gitea-oauth >/dev/null 2>&1; then
  log "drone-gitea-oauth already exists - reusing it"
else
  oauth=$(gitea_api POST "/user/applications/oauth2" \
    "{\"name\":\"drone\",\"redirect_uris\":[\"${DRONE_REDIRECT}\"],\"confidential_client\":true}")

  CLIENT_ID=$(printf '%s' "$oauth" | jq -r '.client_id // empty')
  CLIENT_SECRET=$(printf '%s' "$oauth" | jq -r '.client_secret // empty')

  [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] \
    || die "could not register the OAuth app in Gitea.
  Response: $oauth"

  kubectl -n ci create secret generic drone-gitea-oauth \
    --from-literal=client-id="$CLIENT_ID" \
    --from-literal=client-secret="$CLIENT_SECRET" \
    --from-literal=admin-user-create="username:${GITEA_ADMIN_USER},admin:true" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "OAuth app registered; secret/drone-gitea-oauth created"
fi

# ---------------------------------------------------------------------------
# 5. Drone
# ---------------------------------------------------------------------------
log "Applying Drone..."
DRONE_SERVER_HOST="${HOST}"
has_real_domain || DRONE_SERVER_HOST="${HOST}:${HTTPS_PORT}"
DRONE_SERVER_PROTO="https"
GITEA_SERVER_URL="http://gitea-http.ci.svc:3000"
export DRONE_SERVER_HOST DRONE_SERVER_PROTO GITEA_SERVER_URL

kubectl apply -f "$CI_DIR/drone/rbac.yaml"
render_template "$CI_DIR/drone/server-deployment.yaml" "$RENDER_DIR/drone-server.yaml" \
  'DRONE_SERVER_HOST DRONE_SERVER_PROTO GITEA_SERVER_URL'
kubectl apply -f "$RENDER_DIR/drone-server.yaml"
kubectl apply -f "$CI_DIR/drone/runner-deployment.yaml"

kubectl -n ci rollout status deployment/drone-server --timeout=180s \
  || die "drone-server did not become Ready. Check: kubectl -n ci logs deploy/drone-server"
kubectl -n ci rollout status deployment/drone-runner --timeout=180s \
  || die "drone-runner did not become Ready. Check: kubectl -n ci logs deploy/drone-runner"
ok "Drone server and runner Ready"

# ---------------------------------------------------------------------------
# 6. Deploy credential + registry pull secret
# ---------------------------------------------------------------------------
"$REPO_ROOT/scripts/deploy-key.sh"
"$REPO_ROOT/scripts/registry-secret.sh"

# ---------------------------------------------------------------------------
# 7. Kong routes for /git and /drone.
# ---------------------------------------------------------------------------
log "Adding Kong routes for Gitea and Drone..."
# Indented to match kong.yaml as stored in the ConfigMap VALUE (services list
# items at 2 spaces) - see the same note in bootstrap-observability.sh.
CI_ROUTES=$(cat <<'ROUTES'

  - name: gitea-service
    url: http://gitea-http.ci.svc:3000
    routes:
      - name: gitea-route
        paths:
          - /git
        strip_path: true
        protocols:
          - https
        https_redirect_status_code: 301

  - name: drone-service
    url: http://drone-server.ci.svc:80
    routes:
      - name: drone-route
        paths:
          - /drone
        strip_path: true
        protocols:
          - https
        https_redirect_status_code: 301
ROUTES
)

if kong_insert_block "gitea-service" "$CI_ROUTES"; then
  kubectl -n platform rollout restart deployment/kong
  kubectl -n platform rollout status deployment/kong --timeout=180s
  ok "Kong routes /git and /drone"
else
  log "Kong already routes /git - leaving the config alone"
fi

log ""
ok "Gitea: ${PUBLIC_BASE}/git/   (user: ${GITEA_ADMIN_USER})"
ok "Drone: ${PUBLIC_BASE}/drone/"
log ""
log "The registry is NOT yet in use. To cut over (staged, reversible):"
log "  1. configure /etc/rancher/k3s/registries.yaml on every node (printed above)"
log "  2. set REGISTRY_MODE=incluster in .env"
log "  3. make build-push        # push images to the Gitea registry"
log "  4. make verify-phase5c"
log "Roll back at any point by setting REGISTRY_MODE=external and re-running."
