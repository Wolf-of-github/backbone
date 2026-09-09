#!/usr/bin/env bash
# Join a machine to the backbone cluster as a k3s WORKER (agent).
# depends_on: [scripts/cluster-up.sh, scripts/lib.sh]
#
#   1. FROM the control-plane machine, over SSH (the master does it):
#        ./scripts/node-join.sh user@<worker-ip>
#      Reads .secrets/cluster-join.env, generates a self-contained install
#      snippet, and runs it on the worker over SSH. Uses ~/.ssh/config for the
#      key, or set SSH_KEY=/path/to/key.pem in .env.
#
#   2. ON the worker machine itself:
#        K3S_URL=https://<server>:6443 K3S_TOKEN=<token> ./scripts/node-join.sh
#
# TAILSCALE=true -> the worker advertises its own `tailscale ip -4` as
# --node-external-ip (each node advertises its own tailnet address).
#
# The worker installs only the k3s agent (its own containerd). No Docker, no kubectl.
set -euo pipefail

TARGET="${1:-}"

# ==========================================================================
# The actual install steps, as a standalone snippet. Emitted with values baked
# in so it can run on the worker with nothing else present (no repo, no lib.sh).
# ==========================================================================
emit_remote_script() {
  local url="$1" token="$2" ver="$3" wireguard="$4" tailscale="$5" role="$6"
  cat <<REMOTE
set -euo pipefail
[ "\$(uname -s)" = "Linux" ] || { echo "ERROR a k3s worker must be Linux" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR curl required" >&2; exit 1; }
command -v sudo >/dev/null 2>&1 || { echo "ERROR sudo required" >&2; exit 1; }

K3S_VER="${ver/-k3s/+k3s}"
EXT_IP=""
TS_IP=""
if [ "${tailscale}" = "true" ]; then
  command -v tailscale >/dev/null 2>&1 || { echo "ERROR TAILSCALE=true but tailscale not installed here - run: curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up" >&2; exit 1; }
  TS_IP="\$(tailscale ip -4 | head -1)"
  [ -n "\$TS_IP" ] || { echo "ERROR could not read this machine's tailscale IP" >&2; exit 1; }
  EXT_IP="\$TS_IP"
  echo "  tailscale: node-ip / flannel-iface / external-ip = \$TS_IP (tailscale0)" >&2
fi

EXEC="agent --node-label=backbone.dev/role=${role}"
[ -n "\$EXT_IP" ] && EXEC="\$EXEC --node-external-ip=\$EXT_IP"
# Pin InternalIP + flannel overlay to the tailnet interface (see cluster-up.sh).
[ -n "\$TS_IP" ] && EXEC="\$EXEC --node-ip=\$TS_IP --flannel-iface=tailscale0"

echo "  joining this machine to ${url} as a worker" >&2
echo "  reachability needed to server/peers: 6443/tcp, 10250/tcp, $([ "$wireguard" = true ] && echo 51820/udp || echo 8472/udp)" >&2

curl -sfL https://get.k3s.io | \\
  INSTALL_K3S_VERSION="\$K3S_VER" \\
  K3S_URL="${url}" \\
  K3S_TOKEN="${token}" \\
  INSTALL_K3S_EXEC="\$EXEC" \\
  sh -s -

sudo systemctl is-active --quiet k3s-agent || sudo systemctl start k3s-agent
echo "  k3s-agent started on \$(hostname)." >&2
REMOTE
}

# ==========================================================================
# Remote mode: `node-join.sh user@host` (run on the MASTER)
# ==========================================================================
if [ -n "$TARGET" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/lib.sh
  . "$SCRIPT_DIR/lib.sh"

  load_env
  : "${K3S_VERSION:?set K3S_VERSION in .env}"
  : "${WIREGUARD:=true}"
  : "${TAILSCALE:=false}"
  : "${SSH_KEY:=}"

  JOIN_ENV="$REPO_ROOT/.secrets/cluster-join.env"
  [ -f "$JOIN_ENV" ] || die "missing $JOIN_ENV - run 'make cluster' on the server first"
  # shellcheck disable=SC1090
  . "$JOIN_ENV"   # -> K3S_URL, K3S_TOKEN

  SSH_OPTS=()
  [ -n "$SSH_KEY" ] && SSH_OPTS+=( -i "$SSH_KEY" )

  log "joining ${TARGET} to ${K3S_URL} (via SSH${SSH_KEY:+, key $SSH_KEY})"
  emit_remote_script "$K3S_URL" "$K3S_TOKEN" "$K3S_VERSION" "$WIREGUARD" "$TAILSCALE" "worker" \
    | ssh "${SSH_OPTS[@]}" "$TARGET" "bash -s"
  ok "join dispatched to ${TARGET}"
  log "watch it register:  KUBECONFIG=\$PWD/kubeconfig kubectl get nodes -w"
  exit 0
fi

# ==========================================================================
# Local mode: run ON the worker.
# ==========================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib.sh" ]; then
  # shellcheck source=scripts/lib.sh
  . "$SCRIPT_DIR/lib.sh"
  if [ -z "${K3S_URL:-}" ] || [ -z "${K3S_TOKEN:-}" ]; then
    CACHED="$REPO_ROOT/.secrets/cluster-join.env"
    # shellcheck disable=SC1090
    [ -f "$CACHED" ] && . "$CACHED"
  fi
fi
[ -n "${K3S_URL:-}" ]   || { echo "ERROR K3S_URL not set (e.g. https://<server>:6443)" >&2; exit 1; }
[ -n "${K3S_TOKEN:-}" ] || { echo "ERROR K3S_TOKEN not set (server: sudo cat /var/lib/rancher/k3s/server/node-token)" >&2; exit 1; }

: "${K3S_VERSION:=v1.30.4+k3s1}"
: "${WIREGUARD:=true}"
: "${TAILSCALE:=false}"
: "${NODE_ROLE:=worker}"

emit_remote_script "$K3S_URL" "$K3S_TOKEN" "$K3S_VERSION" "$WIREGUARD" "$TAILSCALE" "$NODE_ROLE" | bash -s
