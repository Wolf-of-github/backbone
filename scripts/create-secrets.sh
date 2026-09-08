#!/usr/bin/env bash
# Create every Phase 0 Kubernetes secret from .env. Idempotent. Never echoes values.
# depends_on: [k8s/base/namespaces.yaml, .env.example, scripts/lib.sh]
#
# Phase 0 creates NONE. The k3s cluster-join token is a node credential (cached to
# .secrets/cluster-join.env by cluster-up.sh), not a K8s Secret. This script is the
# stable entrypoint that later phases (<phase>-secrets.sh) plug into.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need kubectl

kubectl get ns platform data app >/dev/null 2>&1 \
  || die "namespaces missing - run 'make base' first"

# --- Phase 1+ add their secrets here, idempotent pattern: -----------------
#   kubectl create secret generic mongodb-credentials \
#     --namespace data \
#     --from-literal=root-username="$MONGO_ROOT_USER" \
#     --from-literal=root-password="$MONGO_ROOT_PASS" \
#     --dry-run=client -o yaml | kubectl apply -f -

ok "Phase 0 has no Kubernetes secrets to create"
