#!/usr/bin/env bash
# Create every Phase 0 secret from .env. Idempotent. Never echoes secret values.
# depends_on: [k8s/base/namespaces.yaml, .env.example, scripts/registry-secret.sh]
#
# Phase 0 owns only the registry pair (delegated to registry-secret.sh).
# Later phases add their own <phase>-secrets.sh; this stays the single entry
# point invoked by `make secrets`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need kubectl

# Namespaces must exist first.
kubectl get ns platform data app >/dev/null 2>&1 \
  || die "namespaces missing - run 'make base' first"

log "creating registry secrets"
"$SCRIPT_DIR/registry-secret.sh"

# --- extend here in later phases ------------------------------------------------
# Example pattern (idempotent, no value echoed):
#   kubectl create secret generic mongodb-credentials \
#     --namespace data \
#     --from-literal=root-username="$MONGO_ROOT_USER" \
#     --from-literal=root-password="$MONGO_ROOT_PASS" \
#     --dry-run=client -o yaml | kubectl apply -f -

ok "all Phase 0 secrets present"
