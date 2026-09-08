#!/usr/bin/env bash
# Create every Phase 0 secret from .env. Idempotent. Never echoes secret values.
# depends_on: [k8s/base/namespaces.yaml, .env.example]
#
# Phase 0 has NO secrets of its own: the k3d built-in registry needs no auth
# (local, in-Docker) and k3d wires node trust automatically. This script is the
# stable entrypoint that later phases (<phase>-secrets.sh) plug into.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need kubectl

kubectl get ns platform data app >/dev/null 2>&1 \
  || die "namespaces missing - run 'make base' first"

# --- Phase 1+ add their secrets here, using the idempotent pattern: --------
#   kubectl create secret generic mongodb-credentials \
#     --namespace data \
#     --from-literal=root-username="$MONGO_ROOT_USER" \
#     --from-literal=root-password="$MONGO_ROOT_PASS" \
#     --dry-run=client -o yaml | kubectl apply -f -

ok "Phase 0 has no secrets to create (k3d registry is unauthenticated + auto-trusted)"
