#!/usr/bin/env bash
# Tear down the k3d cluster (and its built-in registry). Local only - nothing remote.
# depends_on: [scripts/cluster-up.sh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars CLUSTER_NAME
need k3d

if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
  k3d cluster delete "${CLUSTER_NAME}"
  ok "deleted cluster '${CLUSTER_NAME}'"
else
  log "cluster '${CLUSTER_NAME}' not found - nothing to do"
fi

rm -f "$REPO_ROOT/kubeconfig" "$REPO_ROOT/config/.k3d-cluster.rendered.yaml"
