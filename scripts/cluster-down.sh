#!/usr/bin/env bash
# Tear down the Phase 0 control plane: uninstall the k3s SERVER on this host.
# Workers must be uninstalled on each worker:
#   sudo /usr/local/bin/k3s-agent-uninstall.sh
# depends_on: [scripts/cluster-up.sh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars CLUSTER_NAME

if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
  log "uninstalling k3s server '${CLUSTER_NAME}' on this machine"
  sudo /usr/local/bin/k3s-uninstall.sh
  ok "k3s server removed"
  log "workers still running? on EACH: sudo /usr/local/bin/k3s-agent-uninstall.sh"
else
  log "no k3s server install found here - nothing to do"
fi

rm -f "$REPO_ROOT/kubeconfig" "$REPO_ROOT/.secrets/cluster-join.env"
