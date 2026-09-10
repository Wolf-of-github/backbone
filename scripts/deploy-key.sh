#!/usr/bin/env bash
# deploy-key.sh
# Purpose: Mint the least-privilege Kubernetes credential CI pipelines deploy
#          with, and register it as a Drone secret.
# depends_on: [k8s/base/namespaces.yaml, k8s/ci/drone/rbac.yaml, scripts/lib.sh]
#
# WHY THIS IS NARROW
# This token is reachable by anything the CI server builds. A pipeline that can
# read Secrets in `app` could exfiltrate the Mongo and JWT keys, so the Role
# below grants ONLY what a rolling deploy needs: update the image on an existing
# Deployment and watch the rollout. No secret access, no pod exec, no create,
# no delete. verify-phase5c.sh asserts the denials, not just the grants.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl

kubectl get ns app >/dev/null 2>&1 || die "namespace 'app' missing - run 'make base' first"

log "Creating the ci-deployer ServiceAccount and Role in ns app..."

kubectl apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-deployer
  namespace: app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-deployer
  namespace: app
rules:
# Update the image and read rollout status. Deliberately no "create" and no
# "delete" - a pipeline may roll an existing service, never invent or remove one.
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "patch", "update"]
- apiGroups: ["apps"]
  resources: ["deployments/status", "replicasets"]
  verbs: ["get", "list", "watch"]
# Read-only pod visibility so `kubectl rollout status` and failure triage work.
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-deployer
  namespace: app
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ci-deployer
subjects:
- kind: ServiceAccount
  name: ci-deployer
  namespace: app
YAML
ok "ServiceAccount/Role/RoleBinding ci-deployer"

# Kubernetes 1.24+ does not auto-create ServiceAccount token Secrets, and k3s
# 1.30 is well past that. Request a bound token explicitly.
log "Requesting a 1-year bound token..."
SA_TOKEN=$(kubectl -n app create token ci-deployer --duration=8760h 2>/dev/null) \
  || die "could not mint a token for ci-deployer"

API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Build a standalone kubeconfig the pipeline can use directly.
DEPLOY_KUBECONFIG=$(cat <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: backbone
  cluster:
    server: ${API_SERVER}
    certificate-authority-data: ${CA_DATA}
contexts:
- name: ci-deployer
  context:
    cluster: backbone
    namespace: app
    user: ci-deployer
current-context: ci-deployer
users:
- name: ci-deployer
  user:
    token: ${SA_TOKEN}
KUBECONFIG
)

# Store it as a Secret in `ci` so pipelines can mount it. Never written to disk
# in the repo and never echoed.
kubectl -n ci create secret generic ci-deploy-kubeconfig \
  --from-literal=kubeconfig="$DEPLOY_KUBECONFIG" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "secret/ci-deploy-kubeconfig (ns ci)"

log ""
log "Register it with Drone so pipelines can reference it as 'kubeconfig':"
log "  drone secret add --repository <org>/<repo> --name kubeconfig \\"
log "    --data \"\$(kubectl -n ci get secret ci-deploy-kubeconfig \\"
log "      -o jsonpath='{.data.kubeconfig}' | base64 -d)\""
log ""
log "Token duration is 1 year - re-run this script to rotate."
