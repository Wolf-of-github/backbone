#!/usr/bin/env bash
# Join a machine to the backbone cluster as a k3s WORKER (agent). Only meaningful
# when the cluster was created with MULTI_NODE=true.
# depends_on: [scripts/cluster-up.sh, scripts/lib.sh]
#
# Two ways to run it:
#
#   1. ON the worker machine itself (Linux):
#        K3S_URL=https://<server>:6443 K3S_TOKEN=<token> ./scripts/node-join.sh
#      (or, if .secrets/cluster-join.env from `make cluster` is present here,
#       just: ./scripts/node-join.sh)
#
#   2. FROM the control-plane machine, over SSH:
#        ./scripts/node-join.sh user@<worker-ip>
#      Reads the cached join creds, ships this script over, runs it there.
#
# The worker installs only the k3s agent (its own containerd). No Docker, no
# k3d, no kubectl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

TARGET="${1:-}"

# ---------------------------------------------------------------------------
# Remote mode: `node-join.sh user@host` - push creds + this script, run there.
# ---------------------------------------------------------------------------
if [ -n "$TARGET" ]; then
  load_env
  : "${K3S_VERSION:?set K3S_VERSION in .env}"
  JOIN_ENV="$REPO_ROOT/.secrets/cluster-join.env"
  [ -f "$JOIN_ENV" ] || die "missing $JOIN_ENV - run 'make cluster' with MULTI_NODE=true on the server first"
  # shellcheck disable=SC1090
  . "$JOIN_ENV"   # -> K3S_URL, K3S_TOKEN
  : "${NODE_EXTERNAL_IP:=}"

  log "joining ${TARGET} to ${K3S_URL} (via SSH)"
  # shellcheck disable=SC2029
  ssh "$TARGET" "K3S_URL='${K3S_URL}' K3S_TOKEN='${K3S_TOKEN}' K3S_VERSION='${K3S_VERSION}' \
                 NODE_EXTERNAL_IP='${NODE_EXTERNAL_IP}' WIREGUARD='${WIREGUARD:-true}' \
                 NODE_ROLE='worker' bash -s" < "$SCRIPT_DIR/node-join.sh"
  ok "join command dispatched to ${TARGET}"
  log "verify from the server: kubectl get nodes -w"
  exit 0
fi

# ---------------------------------------------------------------------------
# Local mode: run ON the worker. Needs K3S_URL + K3S_TOKEN (env or cached file).
# ---------------------------------------------------------------------------
if [ -z "${K3S_URL:-}" ] || [ -z "${K3S_TOKEN:-}" ]; then
  CACHED="$REPO_ROOT/.secrets/cluster-join.env"
  if [ -f "$CACHED" ]; then
    # shellcheck disable=SC1090
    . "$CACHED"
  fi
fi
[ -n "${K3S_URL:-}" ]   || die "K3S_URL not set (e.g. https://<server>:6443)"
[ -n "${K3S_TOKEN:-}" ] || die "K3S_TOKEN not set (from server: sudo cat /var/lib/rancher/k3s/server/node-token)"

[ "$(uname -s)" = "Linux" ] || die "a k3s worker must be Linux"
command -v curl >/dev/null 2>&1 || die "curl required"
command -v sudo >/dev/null 2>&1 || die "sudo required"

: "${K3S_VERSION:=v1.30.4-k3s1}"
K3S_VER="${K3S_VERSION/-k3s/+k3s}"     # image tag -> installer channel
: "${NODE_EXTERNAL_IP:=}"
: "${WIREGUARD:=true}"
: "${NODE_ROLE:=worker}"

EXEC_ARGS=( "agent" "--node-label=backbone.dev/role=${NODE_ROLE}" )
[ -n "$NODE_EXTERNAL_IP" ] && EXEC_ARGS+=( "--node-external-ip=${NODE_EXTERNAL_IP}" )

echo "  joining this machine to ${K3S_URL} as a worker (overlay: $([ "$WIREGUARD" = true ] && echo WireGuard || echo VXLAN))" >&2
echo "  required open to the server/peers: 6443/tcp, 10250/tcp, $([ "$WIREGUARD" = true ] && echo 51820/udp || echo 8472/udp)" >&2

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VER}" \
  K3S_URL="${K3S_URL}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="${EXEC_ARGS[*]}" \
  sh -s -

sudo systemctl is-active --quiet k3s-agent || sudo systemctl start k3s-agent
echo "  k3s-agent started. Confirm from the control plane: kubectl get nodes" >&2
