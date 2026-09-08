#!/usr/bin/env bash
# Phase 0 acceptance gate. Exits non-zero on the first failed assertion.
# depends_on: [scripts/install-k3s.sh, k8s/base/storageclass.yaml,
#              k8s/base/namespaces.yaml, scripts/bootstrap-registry.sh,
#              config/registries.yaml.example]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars REGISTRY_HOST REGISTRY_PORT REGISTRY_USER REGISTRY_PASS
need kubectl

fail() { die "verify-phase0: $*"; }

# 1. Node(s) Ready.
log "[1/5] nodes Ready"
kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null \
  || fail "not all nodes Ready"
ok "$(kubectl get nodes --no-headers | wc -l | xargs) node(s) Ready"

# 2. Exactly one default StorageClass, and it is local-path.
log "[2/5] default StorageClass"
defaults="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')"
[ "$(printf '%s\n' "$defaults" | grep -c .)" -eq 1 ] || fail "expected 1 default SC, got: ${defaults:-none}"
[ "$defaults" = "local-path" ] || fail "default SC is '$defaults', expected local-path"
ok "default StorageClass = local-path"

# 3. Namespaces exist.
log "[3/5] namespaces"
for ns in platform data app; do
  kubectl get ns "$ns" >/dev/null 2>&1 || fail "namespace $ns missing"
done
ok "namespaces platform, data, app present"

# 4. A PVC binds (proves the provisioner works end to end).
log "[4/5] PVC binds"
PVC_NAME="verify-phase0-pvc-$$"
cleanup_pvc() { kubectl -n data delete pvc "$PVC_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup_pvc EXIT
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
YAML
# local-path is WaitForFirstConsumer: bind a throwaway pod to force provisioning.
POD_NAME="verify-phase0-pod-$$"
cleanup_pod() { kubectl -n data delete pod "$POD_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap 'cleanup_pod; cleanup_pvc' EXIT
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: data
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","echo phase0 > /d/ok && sleep 5"]
      volumeMounts: [{name: v, mountPath: /d}]
  volumes:
    - name: v
      persistentVolumeClaim:
        claimName: $PVC_NAME
YAML
kubectl -n data wait --for=jsonpath='{.status.phase}'=Bound "pvc/$PVC_NAME" --timeout=90s >/dev/null \
  || fail "PVC $PVC_NAME did not bind"
ok "test PVC bound and mounted"
cleanup_pod; cleanup_pvc; trap - EXIT

# 5. Push + pull to the private registry (auth + TLS + node trust).
log "[5/5] registry push/pull"
need_one() { command -v "$1" >/dev/null 2>&1; }
TAG="${REGISTRY_HOST}:${REGISTRY_PORT}/verify:$(date +%s)"
if need_one docker; then
  RUN=docker
elif need_one nerdctl; then
  RUN="sudo nerdctl"
else
  fail "need docker or nerdctl to test registry push"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
printf 'FROM scratch\nCOPY hello /hello\n' > "$WORKDIR/Dockerfile"
printf 'phase0\n' > "$WORKDIR/hello"

echo "$REGISTRY_PASS" | $RUN login "${REGISTRY_HOST}:${REGISTRY_PORT}" \
  --username "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
  || fail "registry login failed"
$RUN build -t "$TAG" "$WORKDIR" >/dev/null 2>&1 || fail "build of test image failed"
$RUN push "$TAG" >/dev/null 2>&1 || fail "push to $TAG failed"
$RUN rmi "$TAG" >/dev/null 2>&1 || true
$RUN pull "$TAG" >/dev/null 2>&1 || fail "pull of $TAG failed"
$RUN rmi "$TAG" >/dev/null 2>&1 || true
ok "pushed and pulled $TAG"

printf '\n\033[32mPHASE 0 OK\033[0m\n' >&2
