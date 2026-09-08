#!/usr/bin/env bash
# Join a machine to the backbone cluster as a k3s WORKER (agent).
# depends_on: [scripts/cluster-up.sh, scripts/lib.sh]
#
# Two ways to run it:
#
#   1. FROM the control-plane machine, over SSH:
#        ./scripts/node-join.sh user@<worker-ip>
#      Reads the cached join creds, ships this script over, runs it there.
#
#   2. ON the worker machine itself (Linux):
#        K3S_URL=https://<server>:6443 K3S_TOKEN=<token> ./scripts/node-join.sh
#      (or, if .secrets/cluster-join.env from `make cluster` is present here,
#       just: ./scripts/node-join.sh)
#
# If TAILSCALE=true in .env, the worker's --node-external-ip is auto-set to
# `tailscale ip -4` ON THE WORKER (each node advertises its own tailnet IP).
#
# The worker installs only the k3s agent (its own containerd). No Docker, no kubectl.
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
  [ -f "$JOIN_ENV" ] || die "missing $JOIN_ENV - run 'make cluster' on the server first"
  # shellcheck disable=SC1090
  . "$JOIN_ENV"   # -> K3S_URL, K3S_TOKEN
  : "${NODE_EXTERNAL_IP:=}"
  : "${WIREGUARD:=true}"
  : "${TAILSCALE:=false}"

  log "joining ${TARGET} to ${K3S_URL} (via SSH)"
  # NODE_EXTERNAL_IP is deliberately NOT forwarded: the remote picks its own
  # (its tailnet IP when TAILSCALE=true, else k3s auto-detects).
  # shellcheck disable=SC2029
  ssh "$TARGET" "K3S_URL='${K3S_URL}' K3S_TOKEN='${K3S_TOKEN}' K3S_VERSION='${K3S_VERSION}' \
                 WIREGUARD='${WIREGUARD}' TAILSCALE='${TAILSCALE}' NODE_ROLE='worker' bash -s" \
    < "$SCRIPT_DIR/node-join.sh"
  ok "join dispatched to ${TARGET}"
  log "watch it register:  KUBECONFIG=\$PWD/kubeconfig kubectl get nodes -w"
  exit 0
fi

# ---------------------------------------------------------------------------
# Local mode: run ON the worker. Needs K3S_URL + K3S_TOKEN (env or cached file).
# ---------------------------------------------------------------------------
if [ -z "${K3S_URL:-}" ] || [ -z "${K3S_TOKEN:-}" ]; then
  CACHED="$REPO_ROOT/.secrets/cluster-join.env"
  # shellcheck disable=SC1090
  [ -f "$CACHED" ] && . "$CACHED"
fi
[ -n "${K3S_URL:-}" ]   || die "K3S_URL not set (e.g. https://<server>:6443)"
[ -n "${K3S_TOKEN:-}" ] || die "K3S_TOKEN not set (server: sudo cat /var/lib/rancher/k3s/server/node-token)"

[ "$(uname -s)" = "Linux" ] || die "a k3s worker must be Linux"
command -v curl >/dev/null 2>&1 || die "curl required"
command -v sudo >/dev/null 2>&1 || die "sudo required"

: "${K3S_VERSION:=v1.30.4+k3s1}"
K3S_VER="${K3S_VERSION/-k3s/+k3s}"
: "${NODE_EXTERNAL_IP:=}"
: "${WIREGUARD:=true}"
: "${NODE_ROLE:=worker}"
: "${TAILSCALE:=false}"

# TAILSCALE=true -> this node advertises its own tailnet IP.
if [ "$TAILSCALE" = "true" ] && [ -z "$NODE_EXTERNAL_IP" ]; then
  command -v tailscale >/dev/null 2>&1 || die "TAILSCALE=true but 'tailscale' not found here - install it and 'sudo tailscale up' first"
  NODE_EXTERNAL_IP="$(tailscale ip -4 | head -1)"
  [ -n "$NODE_EXTERNAL_IP" ] || die "could not read this machine's tailscale IP"
  echo "  tailscale: advertising this node as ${NODE_EXTERNAL_IP}" >&2
fi

EXEC_ARGS=( "agent" "--node-label=backbone.dev/role=${NODE_ROLE}" )
[ -n "$NODE_EXTERNAL_IP" ] && EXEC_ARGS+=( "--node-external-ip=${NODE_EXTERNAL_IP}" )

echo "  joining this machine to ${K3S_URL} as a worker" >&2
echo "  reachability needed to the server/peers: 6443/tcp, 10250/tcp, $([ "$WIREGUARD" = true ] && echo 51820/udp || echo 8472/udp)" >&2

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VER}" \
  K3S_URL="${K3S_URL}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="${EXEC_ARGS[*]}" \
  sh -s -

sudo systemctl is-active --quiet k3s-agent || sudo systemctl start k3s-agent
echo "  k3s-agent started. Confirm from the control plane: kubectl get nodes" >&2
