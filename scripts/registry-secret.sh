#!/usr/bin/env bash
# registry-secret.sh
# Purpose: Mint a Gitea deploy token and wrap it as the `registry-credentials`
#          docker-registry Secret that app pods pull images with.
# depends_on: [scripts/gitea-secrets.sh, k8s/ci/gitea/service.yaml, scripts/lib.sh]
#
# HISTORY: a file of this name was listed as DROPPED in the Phase 0 manifest,
# when the plan called for a standalone registry. It is reinstated here with a
# different implementation - the registry is Gitea's built-in one, and this
# mints a Gitea token rather than an htpasswd entry. See architecture.txt,
# "Files (Phase 0 - Substrate)" > DROPPED.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need jq

require_vars GITEA_ADMIN_USER GITEA_ADMIN_PASSWORD

GITEA_SVC="gitea-http.ci.svc:3000"
TOKEN_NAME="backbone-registry"
HELPER_POD="registry-token-$$"

cleanup() {
  kubectl -n ci delete pod "$HELPER_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Talk to Gitea from inside the cluster - it has no public API route, and this
# avoids depending on Kong being up to configure the registry.
#
# Credentials go in via --env and are read by curl from the environment
# (-u "$GITEA_AUTH" inside the pod), never interpolated into the command
# string: a password containing a quote or a $ would otherwise break the shell
# or, worse, execute. Same rule as the rest of the repo - no shell string
# interpolation of untrusted or secret values.
gitea_api() {
  local method="$1" path="$2" body="${3:-}"
  kubectl -n ci run "$HELPER_POD" --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet \
    --env="GITEA_AUTH=${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    --env="REQ_METHOD=$method" \
    --env="REQ_PATH=$path" \
    --env="REQ_BODY=$body" \
    --env="GITEA_SVC=$GITEA_SVC" \
    -- sh -c '
      if [ -n "$REQ_BODY" ]; then
        curl -s -X "$REQ_METHOD" -u "$GITEA_AUTH" \
          -H "Content-Type: application/json" \
          -d "$REQ_BODY" "http://$GITEA_SVC/api/v1$REQ_PATH"
      else
        curl -s -X "$REQ_METHOD" -u "$GITEA_AUTH" \
          -H "Content-Type: application/json" \
          "http://$GITEA_SVC/api/v1$REQ_PATH"
      fi
    ' 2>/dev/null
}

log "Minting a Gitea deploy token for the container registry..."

# Tokens cannot be read back after creation, so a re-run deletes and recreates.
gitea_api DELETE "/users/$GITEA_ADMIN_USER/tokens/$TOKEN_NAME" >/dev/null 2>&1 || true

# write:package is the scope the registry needs; read:user lets `docker login`
# validate. Nothing else is granted.
resp=$(gitea_api POST "/users/$GITEA_ADMIN_USER/tokens" \
  "{\"name\":\"$TOKEN_NAME\",\"scopes\":[\"write:package\",\"read:package\",\"read:user\"]}")

TOKEN=$(printf '%s' "$resp" | jq -r '.sha1 // empty')
[ -n "$TOKEN" ] || die "could not create a Gitea token.
  Response: $resp
  Check Gitea is Ready:  kubectl -n ci get pods -l app=gitea
  and that GITEA_ADMIN_USER / GITEA_ADMIN_PASSWORD in .env match the admin account."

# The Secret goes in both namespaces that pull images: `app` runs the services,
# `ci` runs build pods that may pull base images from the same registry.
for ns in app ci; do
  kubectl -n "$ns" create secret docker-registry registry-credentials \
    --docker-server="$GITEA_SVC" \
    --docker-username="$GITEA_ADMIN_USER" \
    --docker-password="$TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "secret/registry-credentials (ns $ns)"
done

# k3s/containerd must trust the registry. It is plain HTTP inside the cluster,
# so every node needs it listed as an insecure endpoint or pulls fail with an
# http-to-https error that reads like a DNS problem.
log ""
log "IMPORTANT - each node needs containerd configured for this registry."
log "On EVERY node (control plane and workers), create"
log "  /etc/rancher/k3s/registries.yaml"
log "containing:"
log ""
log "  mirrors:"
log "    \"$GITEA_SVC\":"
log "      endpoint:"
log "        - \"http://$GITEA_SVC\""
log ""
log "then: sudo systemctl restart k3s        # or k3s-agent on a worker"
log "Skipping this makes every pull fail once REGISTRY_MODE=incluster."
