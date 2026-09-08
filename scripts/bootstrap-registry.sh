#!/usr/bin/env bash
# Stand up the private registry: secrets -> manifests -> node trust -> wait ready.
# depends_on: [k8s/base/namespaces.yaml, k8s/base/storageclass.yaml, scripts/registry-secret.sh]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars REGISTRY_HOST REGISTRY_PORT REGISTRY_USER REGISTRY_PASS
need kubectl
need sed

REG_DIR="$REPO_ROOT/k8s/platform/registry"

# 1. Namespaces + default StorageClass (idempotent; safe if already applied).
kubectl apply -f "$REPO_ROOT/k8s/base/namespaces.yaml"
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  >/dev/null 2>&1 || true

# 2. Secrets.
"$SCRIPT_DIR/registry-secret.sh"

# 3. Manifests.
kubectl apply -f "$REG_DIR/pvc.yaml"
kubectl apply -f "$REG_DIR/deployment.yaml"
kubectl apply -f "$REG_DIR/service.yaml"

log "waiting for registry rollout"
kubectl -n platform rollout status deploy/registry --timeout=120s

# 4. Node trust: render registries.yaml from the template + .env, install on nodes.
TEMPLATE="$REPO_ROOT/config/registries.yaml.example"
RENDERED="$REPO_ROOT/config/registries.yaml"     # gitignored (has credentials)
CA_SRC="$REPO_ROOT/.secrets/registry-ca.crt"
[ -f "$TEMPLATE" ] || die "missing $TEMPLATE"
[ -f "$CA_SRC" ]   || die "missing $CA_SRC - run registry-secret.sh"

sed -e "s|<REGISTRY_HOST>|${REGISTRY_HOST}|g" \
    -e "s|<REGISTRY_PORT>|${REGISTRY_PORT}|g" \
    -e "s|<REGISTRY_USER>|${REGISTRY_USER}|g" \
    -e "s|<REGISTRY_PASS>|${REGISTRY_PASS}|g" \
    "$TEMPLATE" > "$RENDERED"
chmod 600 "$RENDERED"

install_on_node() {
  # $1 = "" for local (sudo), otherwise "user@ip" for ssh.
  local target="$1"
  if [ -z "$target" ]; then
    sudo install -m 0600 "$RENDERED" /etc/rancher/k3s/registries.yaml
    sudo install -m 0644 "$CA_SRC"   /etc/rancher/k3s/registry-ca.crt
    sudo systemctl restart k3s || sudo systemctl restart k3s-agent || true
  else
    scp "$RENDERED" "$CA_SRC" "${target}:/tmp/"
    # shellcheck disable=SC2029
    ssh "$target" 'sudo install -m 0600 /tmp/registries.yaml /etc/rancher/k3s/registries.yaml && \
                   sudo install -m 0644 /tmp/registry-ca.crt /etc/rancher/k3s/registry-ca.crt && \
                   (sudo systemctl restart k3s-agent || sudo systemctl restart k3s) && \
                   rm -f /tmp/registries.yaml /tmp/registry-ca.crt'
  fi
}

log "installing registries.yaml on the server node"
install_on_node ""

if [ -n "${K3S_NODE_IPS:-}" ]; then
  IFS=',' read -ra NODES <<< "$K3S_NODE_IPS"
  for ip in "${NODES[@]}"; do
    ip="$(echo "$ip" | xargs)"   # trim
    [ -n "$ip" ] || continue
    log "installing registries.yaml on agent $ip (ssh)"
    install_on_node "${SUDO_USER:-$USER}@${ip}" || log "WARN: could not reach $ip - install manually"
  done
fi

log "waiting for node(s) Ready after k3s restart"
kubectl wait --for=condition=Ready node --all --timeout=120s

ok "registry up. push URL: ${REGISTRY_HOST}:${REGISTRY_PORT}"
