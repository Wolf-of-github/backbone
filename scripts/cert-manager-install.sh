#!/usr/bin/env bash
# cert-manager-install.sh
# Purpose: Install cert-manager (pinned static manifest) and wait until its
#          admission webhook actually serves - not merely until its pods are Ready.
# depends_on: [scripts/lib.sh]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

need kubectl

# Pinned deliberately. Tracking 'latest' would make cluster bring-up depend on
# whatever cert-manager released this morning.
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

log "Installing cert-manager ${CERT_MANAGER_VERSION}..."

if kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then
  log "cert-manager already present - reapplying manifest (idempotent)"
fi

kubectl apply -f "$MANIFEST"

log "Waiting for cert-manager Deployments to become Available..."
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  kubectl -n cert-manager rollout status "deployment/$d" --timeout=180s \
    || die "cert-manager: deployment/$d did not become Ready"
done

# The webhook Deployment reporting Ready precedes it actually serving TLS. An
# Issuer applied in that gap fails with an x509/connection-refused handshake
# error, which reads like a broken install but is only a race. Poll by
# dry-run-applying a throwaway Issuer until the API accepts it.
log "Waiting for the cert-manager admission webhook to serve..."
probe='{"apiVersion":"cert-manager.io/v1","kind":"Issuer",
        "metadata":{"name":"webhook-readiness-probe","namespace":"cert-manager"},
        "spec":{"selfSigned":{}}}'

webhook_ready=false
for _ in $(seq 1 45); do
  if printf '%s' "$probe" | kubectl apply --dry-run=server -f - >/dev/null 2>&1; then
    webhook_ready=true
    break
  fi
  sleep 2
done

[ "$webhook_ready" = true ] \
  || die "cert-manager webhook never became ready (waited 90s).
  Check: kubectl -n cert-manager logs deploy/cert-manager-webhook"

ok "cert-manager ${CERT_MANAGER_VERSION} installed and webhook serving"
