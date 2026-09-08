#!/usr/bin/env bash
# Bring up the Phase 0 control plane: a k3s SERVER on this Linux host.
# Other machines join as workers with scripts/node-join.sh. Idempotent.
# depends_on: [.env.example, scripts/lib.sh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars K3S_VERSION CLUSTER_NAME K3S_SERVER_ADDR
: "${WIREGUARD:=true}"
: "${NODE_ROLE:=control-plane}"
: "${NODE_EXTERNAL_IP:=}"

[ "$(uname -s)" = "Linux" ] || die "backbone runs on Linux. cluster-up.sh installs a k3s server here.
  Run it on the machine that will be the control plane (a Linux VM / bare metal / EC2)."
need curl
command -v sudo >/dev/null 2>&1 || die "sudo required"

mkdir -p "$REPO_ROOT/.secrets"; chmod 700 "$REPO_ROOT/.secrets"

# k3s version: accept both the image-style tag (v1.30.4-k3s1) and the
# installer channel (v1.30.4+k3s1); normalise to the latter.
K3S_VER="${K3S_VERSION/-k3s/+k3s}"

EXEC_ARGS=(
  "server"
  "--cluster-init"                       # embedded etcd - can grow to 3-server HA later
  "--tls-san=${K3S_SERVER_ADDR}"
  "--disable=traefik"                    # Kong is the gateway (Phase 2)
  "--node-label=backbone.dev/role=${NODE_ROLE}"
  "--write-kubeconfig-mode=0644"
)
[ -n "$NODE_EXTERNAL_IP" ] && EXEC_ARGS+=( "--node-external-ip=${NODE_EXTERNAL_IP}" )
if [ "$WIREGUARD" = "true" ]; then
  EXEC_ARGS+=( "--flannel-backend=wireguard-native" )
  log "node-to-node overlay: WireGuard (encrypted). Open 51820/udp between nodes."
else
  log "node-to-node overlay: plain VXLAN. Open 8472/udp between nodes (trusted network only)."
fi

if command -v k3s >/dev/null 2>&1 && sudo systemctl is-active --quiet k3s 2>/dev/null; then
  log "k3s server already running - reconciling config only"
else
  log "installing k3s server ${K3S_VER} (API advertised at https://${K3S_SERVER_ADDR}:6443)"
fi

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VER}" \
  INSTALL_K3S_EXEC="${EXEC_ARGS[*]}" \
  sh -s -

sudo systemctl is-active --quiet k3s || sudo systemctl start k3s

# Repo-local kubeconfig, server URL rewritten to the advertised address.
SRC="/etc/rancher/k3s/k3s.yaml"
DST="$REPO_ROOT/kubeconfig"
for _ in $(seq 1 30); do [ -f "$SRC" ] && break; sleep 2; done
[ -f "$SRC" ] || die "$SRC never appeared"
sudo cat "$SRC" | sed "s|https://127.0.0.1:6443|https://${K3S_SERVER_ADDR}:6443|" > "$DST"
chmod 600 "$DST"
ok "wrote $DST"

# Cache the join token where node-join.sh (and only the owner) can read it.
TOK="$(sudo cat /var/lib/rancher/k3s/server/node-token)"
umask 077
printf 'K3S_URL=https://%s:6443\nK3S_TOKEN=%s\n' "${K3S_SERVER_ADDR}" "${TOK}" \
  > "$REPO_ROOT/.secrets/cluster-join.env"
ok "join credentials cached at .secrets/cluster-join.env (gitignored)"

export KUBECONFIG="$DST"

# The API server accepts connections a moment before the node object is
# registered, so `kubectl wait node` can race with "no matching resources".
# Wait for the object to appear first, then wait for it to go Ready.
log "waiting for the node object to register"
for _ in $(seq 1 60); do
  [ -n "$(kubectl get nodes -o name 2>/dev/null)" ] && break
  sleep 2
done
[ -n "$(kubectl get nodes -o name 2>/dev/null)" ] \
  || die "node never registered - check: sudo journalctl -u k3s -f"

log "waiting for server node Ready (timeout 120s)"
kubectl wait --for=condition=Ready node --all --timeout=120s

# k3s creates the local-path StorageClass via a deployment a few seconds after
# the node is Ready. Wait for it so `make base` can patch it as default.
log "waiting for the local-path StorageClass"
for _ in $(seq 1 30); do
  kubectl get storageclass local-path >/dev/null 2>&1 && break
  sleep 2
done
kubectl get storageclass local-path >/dev/null 2>&1 \
  || die "local-path StorageClass never appeared - is the local-path-provisioner pod running? (kubectl -n kube-system get pods)"

kubectl get nodes -o wide -L backbone.dev/role >&2

ok "cluster ready (k3s server: ${CLUSTER_NAME})"
log ""
log "Add a worker machine - option 1 (from THIS host, over SSH):"
log "    ./scripts/node-join.sh user@<worker-ip>"
log "Add a worker machine - option 2 (on the worker itself):"
log "    K3S_URL=https://${K3S_SERVER_ADDR}:6443 K3S_TOKEN=<token> ./scripts/node-join.sh"
log ""
log "Firewall between nodes: 6443/tcp, 10250/tcp$( [ "$WIREGUARD" = true ] && echo ', 51820/udp' || echo ', 8472/udp' )"
