#!/usr/bin/env bash
# Create the Phase 0 cluster: k3s running in Docker via k3d. Machine-agnostic
# (Linux / macOS / Windows+WSL2 - anywhere Docker runs). Idempotent.
# depends_on: [.env.example, config/k3d-cluster.yaml]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars K3S_VERSION CLUSTER_NAME HTTP_PORT HTTPS_PORT REGISTRY_NAME REGISTRY_PORT
: "${K3D_AGENTS:=0}"
: "${REGISTRY_INTERNAL_PORT:=5000}"

need docker
docker info >/dev/null 2>&1 || die "Docker daemon not reachable - start Docker Desktop / dockerd"

# --- ensure k3d ------------------------------------------------------------
if ! command -v k3d >/dev/null 2>&1; then
  die "k3d not found. Install it:
    macOS/Linux : curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    Homebrew    : brew install k3d
    Windows     : choco install k3d   (or scoop install k3d)"
fi
log "k3d $(k3d version | awk '/k3d version/{print $3}')  |  docker $(docker version -f '{{.Server.Version}}')"

TEMPLATE="$REPO_ROOT/config/k3d-cluster.yaml"
RENDERED="$REPO_ROOT/config/.k3d-cluster.rendered.yaml"   # gitignored
[ -f "$TEMPLATE" ] || die "missing $TEMPLATE"

sed -e "s|<CLUSTER_NAME>|${CLUSTER_NAME}|g" \
    -e "s|<K3S_VERSION>|${K3S_VERSION}|g" \
    -e "s|<K3D_AGENTS>|${K3D_AGENTS}|g" \
    -e "s|<HTTP_PORT>|${HTTP_PORT}|g" \
    -e "s|<HTTPS_PORT>|${HTTPS_PORT}|g" \
    -e "s|<REGISTRY_NAME>|${REGISTRY_NAME}|g" \
    -e "s|<REGISTRY_PORT>|${REGISTRY_PORT}|g" \
    "$TEMPLATE" > "$RENDERED"

# --- create (or reuse) the cluster --------------------------------------------
if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
  log "cluster '${CLUSTER_NAME}' already exists - reusing"
  k3d cluster start "${CLUSTER_NAME}" >/dev/null 2>&1 || true
else
  log "creating k3d cluster '${CLUSTER_NAME}' (k3s ${K3S_VERSION}, ${K3D_AGENTS} agent(s))"
  k3d cluster create --config "$RENDERED"
fi

# --- repo-local kubeconfig ------------------------------------------------
DST_KUBECONFIG="$REPO_ROOT/kubeconfig"
k3d kubeconfig get "${CLUSTER_NAME}" > "$DST_KUBECONFIG"
chmod 600 "$DST_KUBECONFIG"
ok "wrote $DST_KUBECONFIG"

export KUBECONFIG="$DST_KUBECONFIG"
log "waiting for node(s) Ready (timeout 120s)"
kubectl wait --for=condition=Ready node --all --timeout=120s
kubectl get nodes -o wide >&2

# k3d's built-in registry is reachable from the host and from inside the cluster
# at the SAME name:port thanks to k3d's hosts injection. Print both forms.
REG_HOST_IN_CLUSTER="${REGISTRY_NAME}:${REGISTRY_INTERNAL_PORT}"
REG_HOST_FROM_HOST="localhost:${REGISTRY_PORT}"
ok "cluster ready"
log "registry (from your machine)  : ${REG_HOST_FROM_HOST}"
log "registry (image refs in k8s)  : ${REG_HOST_IN_CLUSTER}"
