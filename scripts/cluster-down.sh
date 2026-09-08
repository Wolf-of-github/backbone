#!/usr/bin/env bash
# Tear down the Phase 0 cluster. Mode-aware (MULTI_NODE in .env).
#   k3d  -> k3d cluster delete (also removes the built-in registry).
#   k3s  -> uninstall the k3s SERVER on this machine. Workers must be
#           uninstalled on each worker: sudo /usr/local/bin/k3s-agent-uninstall.sh
# depends_on: [scripts/cluster-up.sh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars CLUSTER_NAME
: "${MULTI_NODE:=false}"

case "$MULTI_NODE" in
  true|1|yes)
    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
      log "uninstalling k3s server on this machine"
      sudo /usr/local/bin/k3s-uninstall.sh
      ok "k3s server removed"
      log "workers still running? on EACH: sudo /usr/local/bin/k3s-agent-uninstall.sh"
    else
      log "no k3s server install found here - nothing to do"
    fi
    rm -f "$REPO_ROOT/kubeconfig" "$REPO_ROOT/.secrets/cluster-join.env"
    ;;
  *)
    need k3d
    if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
      k3d cluster delete "${CLUSTER_NAME}"
      ok "deleted cluster '${CLUSTER_NAME}'"
    else
      log "cluster '${CLUSTER_NAME}' not found - nothing to do"
    fi
    rm -f "$REPO_ROOT/kubeconfig" "$REPO_ROOT/config/.k3d-cluster.rendered.yaml"
    ;;
esac
