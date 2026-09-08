#!/usr/bin/env bash
# Install a pinned k3s server, write a repo-local ./kubeconfig, wait for Ready.
# depends_on: [.env.example, config/k3s-config.yaml]
#
# Single-node by default. If K3S_NODE_IPS is set in .env, prints the agent
# join command (run it yourself on each agent, or via scripts/worker-node-join.sh
# in Phase 6).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars K3S_VERSION K3S_SERVER_IP DOMAIN
need curl
need sudo

CONFIG_SRC="$REPO_ROOT/config/k3s-config.yaml"
CONFIG_DST="/etc/rancher/k3s/config.yaml"
[ -f "$CONFIG_SRC" ] || die "missing $CONFIG_SRC"

if command -v k3s >/dev/null 2>&1; then
  log "k3s already installed ($(k3s --version | head -1)); reapplying config only"
else
  log "installing k3s $K3S_VERSION"
fi

# Render config: substitute the two placeholders from .env.
render_config() {
  sed -e "s|<K3S_SERVER_IP>|${K3S_SERVER_IP}|g" \
      -e "s|<DOMAIN>|${DOMAIN}|g" \
      "$CONFIG_SRC"
}
sudo mkdir -p /etc/rancher/k3s
render_config | sudo tee "$CONFIG_DST" >/dev/null
sudo chmod 0600 "$CONFIG_DST"
ok "wrote $CONFIG_DST"

# Install / upgrade the server. INSTALL_K3S_EXEC picks up --config automatically.
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="server" \
  sh -s -

log "waiting for k3s service to be active"
sudo systemctl is-active --quiet k3s || sudo systemctl start k3s

# Write a user-owned kubeconfig at the repo root, pointing at the real server IP.
SRC_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
DST_KUBECONFIG="$REPO_ROOT/kubeconfig"
for _ in $(seq 1 30); do
  [ -f "$SRC_KUBECONFIG" ] && break
  sleep 2
done
[ -f "$SRC_KUBECONFIG" ] || die "$SRC_KUBECONFIG never appeared"

sudo cat "$SRC_KUBECONFIG" \
  | sed "s|https://127.0.0.1:6443|https://${K3S_SERVER_IP}:6443|" \
  > "$DST_KUBECONFIG"
chmod 0600 "$DST_KUBECONFIG"
ok "wrote $DST_KUBECONFIG"

export KUBECONFIG="$DST_KUBECONFIG"
log "waiting for node(s) Ready (timeout 120s)"
kubectl wait --for=condition=Ready node --all --timeout=120s
kubectl get nodes -o wide >&2

# Agent join instructions.
if [ -n "${K3S_NODE_IPS:-}" ]; then
  TOKEN="$(sudo cat /var/lib/rancher/k3s/server/node-token)"
  log ""
  log "To join agents, run ON EACH of: ${K3S_NODE_IPS}"
  log "  curl -sfL https://get.k3s.io | K3S_URL=https://${K3S_SERVER_IP}:6443 K3S_TOKEN=${TOKEN} INSTALL_K3S_VERSION=${K3S_VERSION} sh -"
fi

ok "k3s ready"
