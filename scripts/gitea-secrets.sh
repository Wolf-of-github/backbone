#!/usr/bin/env bash
# gitea-secrets.sh
# Purpose: Phase 5C secrets - Gitea admin/internal keys and the shared Drone
#          RPC secret. Plugs into the create-secrets.sh convention from Phase 0.
# depends_on: [k8s/base/namespaces.yaml, scripts/create-secrets.sh, scripts/lib.sh]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need openssl

kubectl get ns ci >/dev/null 2>&1 \
  || die "namespace 'ci' missing - run 'make base' first"

require_vars GITEA_ADMIN_USER GITEA_ADMIN_PASSWORD GITEA_ADMIN_EMAIL DRONE_RPC_SECRET

# Gitea's own SECRET_KEY and INTERNAL_TOKEN. Unlike the .env-sourced values,
# these are generated once and then PRESERVED: SECRET_KEY encrypts stored OAuth
# tokens and 2FA secrets, so regenerating it on every run would silently
# invalidate them. Read back an existing secret rather than minting a new one.
if kubectl -n ci get secret gitea-admin >/dev/null 2>&1; then
  log "gitea-admin exists - preserving SECRET_KEY / INTERNAL_TOKEN"
  SECRET_KEY=$(kubectl -n ci get secret gitea-admin -o jsonpath='{.data.secret-key}' | base64 -d)
  INTERNAL_TOKEN=$(kubectl -n ci get secret gitea-admin -o jsonpath='{.data.internal-token}' | base64 -d)
else
  log "generating Gitea SECRET_KEY and INTERNAL_TOKEN"
  SECRET_KEY=$(openssl rand -base64 32 | tr -d '\n')
  INTERNAL_TOKEN=$(openssl rand -base64 48 | tr -d '\n')
fi

kubectl -n ci create secret generic gitea-admin \
  --from-literal=username="$GITEA_ADMIN_USER" \
  --from-literal=password="$GITEA_ADMIN_PASSWORD" \
  --from-literal=email="$GITEA_ADMIN_EMAIL" \
  --from-literal=secret-key="$SECRET_KEY" \
  --from-literal=internal-token="$INTERNAL_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "secret/gitea-admin (ns ci)"

kubectl -n ci create secret generic drone-rpc-secret \
  --from-literal=rpc-secret="$DRONE_RPC_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "secret/drone-rpc-secret (ns ci)"

log "Note: changing these in .env requires a rollout restart to take effect:"
log "  kubectl -n ci rollout restart statefulset/gitea deployment/drone-server deployment/drone-runner"
