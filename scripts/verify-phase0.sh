#!/usr/bin/env bash
# Phase 0 acceptance gate. Exits non-zero on the first failed assertion.
# depends_on: [scripts/cluster-up.sh, k8s/base/storageclass.yaml,
#              k8s/base/namespaces.yaml]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars CLUSTER_NAME
: "${MULTI_NODE:=false}"
: "${REGISTRY_INTERNAL_PORT:=5000}"
need kubectl

fail() { die "verify-phase0: $*"; }

case "$MULTI_NODE" in
  true|1|yes) MODE=k3s ;;
  *)          MODE=k3d ; require_vars REGISTRY_NAME REGISTRY_PORT ; need docker ;;
esac
log "mode: $MODE"

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

# 3. Namespaces exist (and their default ServiceAccount has been provisioned -
#    the token controller creates it a beat after the namespace).
log "[3/5] namespaces"
for ns in platform data app; do
  kubectl get ns "$ns" >/dev/null 2>&1 || fail "namespace $ns missing"
  for _ in $(seq 1 30); do
    kubectl -n "$ns" get serviceaccount default >/dev/null 2>&1 && break
    sleep 1
  done
  kubectl -n "$ns" get serviceaccount default >/dev/null 2>&1 \
    || fail "namespace $ns has no default ServiceAccount yet"
done
ok "namespaces platform, data, app present"

# 4. A PVC binds (proves the local-path provisioner works end to end).
log "[4/5] PVC binds"
PVC_NAME="verify-phase0-pvc-$$"
POD_NAME="verify-phase0-pod-$$"
cleanup4() {
  kubectl -n data delete pod "$POD_NAME"  --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n data delete pvc "$PVC_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup4 EXIT
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $PVC_NAME, namespace: data }
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: $POD_NAME, namespace: data }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","echo phase0 > /d/ok && cat /d/ok && sleep 5"]
      volumeMounts: [{ name: v, mountPath: /d }]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: $PVC_NAME }
YAML
kubectl -n data wait --for=jsonpath='{.status.phase}'=Bound "pvc/$PVC_NAME" --timeout=90s >/dev/null \
  || fail "PVC $PVC_NAME did not bind"
ok "test PVC bound and mounted"
cleanup4; trap - EXIT

# 5. Image pull works.
#    k3d mode: prove the built-in registry (push from host -> pull in-cluster).
#    k3s multi-node mode: no in-cluster registry until Phase 5; just prove every
#    node can pull an image (schedule a pod per node via a DaemonSet-style spread).
POD_NAME="verify-phase0-regpull-$$"
WORKDIR=""
cleanup5() {
  kubectl -n data delete pod -l verify=phase0 --ignore-not-found --wait=false >/dev/null 2>&1 || true
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR" || true
}
trap cleanup5 EXIT

if [ "$MODE" = "k3d" ]; then
  log "[5/5] registry push/pull (k3d built-in registry)"
  docker info >/dev/null 2>&1 || fail "docker daemon not reachable"
  TAG="verify:$(date +%s)"
  HOST_REF="localhost:${REGISTRY_PORT}/${TAG}"
  CLUSTER_REF="${REGISTRY_NAME}:${REGISTRY_INTERNAL_PORT}/${TAG}"
  WORKDIR="$(mktemp -d)"
  printf 'FROM busybox:1.36\nRUN echo phase0 > /phase0\n' > "$WORKDIR/Dockerfile"
  docker build -t "$HOST_REF" "$WORKDIR" >/dev/null 2>&1 || fail "build of test image failed"
  docker push  "$HOST_REF" >/dev/null 2>&1 || fail "push to $HOST_REF failed (is the k3d registry running?)"
  docker rmi   "$HOST_REF" >/dev/null 2>&1 || true
  kubectl -n data run "$POD_NAME" --labels=verify=phase0 --restart=Never --image="$CLUSTER_REF" \
    --command -- sh -c 'cat /phase0' >/dev/null
  kubectl -n data wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD_NAME" --timeout=90s >/dev/null \
    || fail "in-cluster pull of $CLUSTER_REF failed"
  ok "pushed ($HOST_REF) and pulled in-cluster ($CLUSTER_REF)"
else
  log "[5/5] every node can pull images"
  NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
  i=0
  for n in $NODES; do
    i=$((i+1))
    cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${POD_NAME}-${i}, namespace: data, labels: { verify: phase0 } }
spec:
  restartPolicy: Never
  nodeName: ${n}
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","echo phase0"]
YAML
  done
  for j in $(seq 1 "$i"); do
    kubectl -n data wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD_NAME}-${j}" --timeout=120s >/dev/null \
      || fail "a node could not pull/run busybox (pod ${POD_NAME}-${j})"
  done
  ok "$i node(s) pulled and ran a test image"
  log "note: the shared in-cluster registry arrives in Phase 5 (behind Kong + TLS)"
fi
cleanup5; trap - EXIT

printf '\n\033[32mPHASE 0 OK\033[0m\n' >&2
