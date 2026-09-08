#!/usr/bin/env bash
# Bring up the Phase 0 cluster. Two modes, selected by MULTI_NODE in .env:
#   MULTI_NODE=false -> k3d (k3s-in-Docker) on this machine only. Idempotent.
#   MULTI_NODE=true  -> a real k3s SERVER on this Linux host that other machines
#                       join as workers via scripts/node-join.sh.
# depends_on: [.env.example, config/k3d-cluster.yaml, scripts/lib.sh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars K3S_VERSION CLUSTER_NAME
: "${MULTI_NODE:=false}"

# ==========================================================================
# Mode A: k3d (single machine, in Docker)
# ==========================================================================
cluster_up_k3d() {
  require_vars HTTP_PORT HTTPS_PORT REGISTRY_NAME REGISTRY_PORT
  : "${K3D_AGENTS:=0}"
  : "${REGISTRY_INTERNAL_PORT:=5000}"

  need docker
  docker info >/dev/null 2>&1 || die "Docker daemon not reachable - start Docker Desktop / dockerd"
  command -v k3d >/dev/null 2>&1 || die "k3d not found. Install it:
    macOS/Linux : curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    Homebrew    : brew install k3d
    Windows     : choco install k3d   (or scoop install k3d)"
  log "k3d $(k3d version | awk '/k3d version/{print $3}')  |  docker $(docker version -f '{{.Server.Version}}')"

  local template="$REPO_ROOT/config/k3d-cluster.yaml"
  local rendered="$REPO_ROOT/config/.k3d-cluster.rendered.yaml"   # gitignored
  [ -f "$template" ] || die "missing $template"

  sed -e "s|<CLUSTER_NAME>|${CLUSTER_NAME}|g" \
      -e "s|<K3S_VERSION>|${K3S_VERSION}|g" \
      -e "s|<K3D_AGENTS>|${K3D_AGENTS}|g" \
      -e "s|<HTTP_PORT>|${HTTP_PORT}|g" \
      -e "s|<HTTPS_PORT>|${HTTPS_PORT}|g" \
      -e "s|<REGISTRY_NAME>|${REGISTRY_NAME}|g" \
      -e "s|<REGISTRY_PORT>|${REGISTRY_PORT}|g" \
      "$template" > "$rendered"

  if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
    log "cluster '${CLUSTER_NAME}' already exists - reusing"
    k3d cluster start "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  else
    log "creating k3d cluster '${CLUSTER_NAME}' (k3s ${K3S_VERSION}, ${K3D_AGENTS} agent(s))"
    k3d cluster create --config "$rendered"
  fi

  local dst="$REPO_ROOT/kubeconfig"
  k3d kubeconfig get "${CLUSTER_NAME}" > "$dst"
  chmod 600 "$dst"
  ok "wrote $dst"

  export KUBECONFIG="$dst"
  log "waiting for node(s) Ready (timeout 120s)"
  kubectl wait --for=condition=Ready node --all --timeout=120s
  kubectl get nodes -o wide >&2

  ok "cluster ready (mode: k3d, single machine)"
  log "registry (from your machine)  : localhost:${REGISTRY_PORT}"
  log "registry (image refs in k8s)  : ${REGISTRY_NAME}:${REGISTRY_INTERNAL_PORT}"
  log "add worker machines? this mode can't - set MULTI_NODE=true and re-run."
}

# ==========================================================================
# Mode B: real k3s server (multi-machine, joinable)
# ==========================================================================
cluster_up_k3s_server() {
  require_vars K3S_SERVER_ADDR
  : "${WIREGUARD:=true}"
  : "${NODE_ROLE:=control-plane}"
  : "${NODE_EXTERNAL_IP:=}"

  [ "$(uname -s)" = "Linux" ] || die "MULTI_NODE=true installs a k3s server and needs Linux.
  Run it on the machine that will be the control plane (a Linux VM / bare metal / EC2).
  For local single-machine use, set MULTI_NODE=false (k3d)."
  need curl
  command -v sudo >/dev/null 2>&1 || die "sudo required"

  # k3d image tag (v1.30.4-k3s1) -> installer channel (v1.30.4+k3s1).
  local k3s_ver="${K3S_VERSION/-k3s/+k3s}"

  local -a exec_args=(
    "server"
    "--cluster-init"
    "--tls-san=${K3S_SERVER_ADDR}"
    "--disable=traefik"
    "--node-label=backbone.dev/role=${NODE_ROLE}"
    "--write-kubeconfig-mode=0644"
  )
  [ -n "$NODE_EXTERNAL_IP" ] && exec_args+=( "--node-external-ip=${NODE_EXTERNAL_IP}" )
  if [ "$WIREGUARD" = "true" ]; then
    exec_args+=( "--flannel-backend=wireguard-native" )
    log "node-to-node overlay: WireGuard (encrypted). Open 51820/udp between nodes."
  else
    log "node-to-node overlay: plain VXLAN. Open 8472/udp between nodes (only safe on a trusted network)."
  fi

  if command -v k3s >/dev/null 2>&1 && sudo systemctl is-active --quiet k3s 2>/dev/null; then
    log "k3s server already running - reconciling config only"
  else
    log "installing k3s server ${k3s_ver} (API advertised at https://${K3S_SERVER_ADDR}:6443)"
  fi

  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${k3s_ver}" \
    INSTALL_K3S_EXEC="${exec_args[*]}" \
    sh -s -

  sudo systemctl is-active --quiet k3s || sudo systemctl start k3s

  # Repo-local kubeconfig, server URL rewritten to the advertised address.
  local src="/etc/rancher/k3s/k3s.yaml" dst="$REPO_ROOT/kubeconfig"
  for _ in $(seq 1 30); do [ -f "$src" ] && break; sleep 2; done
  [ -f "$src" ] || die "$src never appeared"
  sudo cat "$src" | sed "s|https://127.0.0.1:6443|https://${K3S_SERVER_ADDR}:6443|" > "$dst"
  chmod 600 "$dst"
  ok "wrote $dst"

  # Cache the join token where node-join.sh (and only the owner) can read it.
  local tok; tok="$(sudo cat /var/lib/rancher/k3s/server/node-token)"
  umask 077
  printf 'K3S_URL=https://%s:6443\nK3S_TOKEN=%s\n' "${K3S_SERVER_ADDR}" "${tok}" \
    > "$REPO_ROOT/.secrets/cluster-join.env"
  ok "join credentials cached at .secrets/cluster-join.env (gitignored)"

  export KUBECONFIG="$dst"
  log "waiting for server node Ready (timeout 120s)"
  kubectl wait --for=condition=Ready node --all --timeout=120s
  kubectl get nodes -o wide -L backbone.dev/role >&2

  ok "cluster ready (mode: k3s server, multi-machine)"
  log ""
  log "Add a worker machine: copy this repo (or just scripts/) to it and run"
  log "    K3S_URL=https://${K3S_SERVER_ADDR}:6443 ./scripts/node-join.sh"
  log "or, from THIS machine with SSH access:"
  log "    ./scripts/node-join.sh user@<worker-ip>"
  log ""
  log "Firewall between nodes: 6443/tcp, 10250/tcp$( [ "$WIREGUARD" = true ] && echo ', 51820/udp' || echo ', 8472/udp' )"
}

# --- dispatch --------------------------------------------------------------
mkdir -p "$REPO_ROOT/.secrets"; chmod 700 "$REPO_ROOT/.secrets"
case "$MULTI_NODE" in
  true|1|yes)  cluster_up_k3s_server ;;
  *)           cluster_up_k3d ;;
esac
