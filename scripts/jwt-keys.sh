#!/usr/bin/env bash
# jwt-keys.sh
# Purpose: Generate RS256 JWT keypair and create k8s secrets in app and platform namespaces
# Depends on: k8s/base/namespaces.yaml, scripts/create-secrets.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

load_env
need kubectl openssl

log "Checking namespaces..."
kubectl get ns app platform >/dev/null 2>&1 || die "Namespaces app and platform must exist. Run 'make base' first."

JWT_SECRETS_DIR="${REPO_ROOT}/.secrets/jwt"
PRIVATE_KEY="${JWT_SECRETS_DIR}/private.pem"
PUBLIC_KEY="${JWT_SECRETS_DIR}/public.pem"

# Generate keypair if not present
if [[ ! -f "${PRIVATE_KEY}" || ! -f "${PUBLIC_KEY}" ]]; then
  log "Generating new RS256 keypair..."
  mkdir -p "${JWT_SECRETS_DIR}"
  chmod 700 "${JWT_SECRETS_DIR}"

  openssl genrsa -out "${PRIVATE_KEY}" 2048
  openssl rsa -in "${PRIVATE_KEY}" -pubout -out "${PUBLIC_KEY}"

  chmod 600 "${PRIVATE_KEY}"
  chmod 644 "${PUBLIC_KEY}"

  ok "JWT keypair generated"
else
  log "Using existing JWT keypair from ${JWT_SECRETS_DIR}"
fi

# Create secrets in both namespaces (idempotent)
log "Creating jwt-keypair secret in app namespace..."
kubectl -n app create secret generic jwt-keypair \
  --from-file=private-key="${PRIVATE_KEY}" \
  --from-file=public-key="${PUBLIC_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Creating jwt-public-key secret in platform namespace..."
kubectl -n platform create secret generic jwt-public-key \
  --from-file=public-key="${PUBLIC_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

ok "JWT secrets created/updated in app and platform namespaces"
