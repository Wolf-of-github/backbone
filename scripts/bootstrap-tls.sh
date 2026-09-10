#!/usr/bin/env bash
# bootstrap-tls.sh
# Purpose: Phase 5A - terminate HTTPS at Kong using a cert-manager certificate.
#          Works with no domain (TLS_MODE=selfsigned) and converges across mode
#          changes, so adding a real domain later is an .env edit plus a re-run.
# depends_on: [scripts/cert-manager-install.sh, scripts/lib.sh,
#              k8s/platform/cert-manager/*, k8s/platform/kong/tls.yaml]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need jq
need envsubst

RENDER_DIR="$REPO_ROOT/.rendered/tls"
CM_DIR="k8s/platform/cert-manager"

# ---------------------------------------------------------------------------
# 1. Resolve TLS_MODE into an issuer + SANs, and reject impossible combinations
#    up front with a message naming the exact .env lines to fix.
# ---------------------------------------------------------------------------
TLS_MODE="${TLS_MODE:-selfsigned}"
NODE_IP="$(node_ip)"
[ -n "$NODE_IP" ] || die "could not determine a Ready node IP - is the cluster up?"

case "$TLS_MODE" in
  selfsigned)
    CERT_ISSUER="backbone-selfsigned"
    CERT_COMMON_NAME="backbone.local"
    # No domain: serve on the node IP. ipAddresses (not just dnsNames) is what
    # makes https://<node-ip> present a cert that actually matches the host.
    CERT_DNS_NAMES='["backbone.local"]'
    CERT_IP_ADDRESSES="[\"${NODE_IP}\"]"
    ;;
  staging|production)
    has_real_domain || die "TLS_MODE=$TLS_MODE needs a real domain.
  In .env set:
    DOMAIN=<your domain>        (currently '${DOMAIN:-unset}')
  Its A record must already point at ${NODE_IP}, and port 80 must be reachable
  from the internet - Let's Encrypt validates over HTTP-01.
  To stay domainless instead, set TLS_MODE=selfsigned."

    [ -n "${ACME_EMAIL:-}" ] || die "TLS_MODE=$TLS_MODE requires ACME_EMAIL in .env
  (Let's Encrypt sends expiry warnings there)."

    if [ "$TLS_MODE" = staging ]; then
      CERT_ISSUER="backbone-staging"
    else
      CERT_ISSUER="backbone-prod"
    fi
    CERT_COMMON_NAME="$DOMAIN"
    # Subdomains for the Phase 5B/5C surfaces, so a later `make obs` / `make ci`
    # needs no new certificate.
    # The embedded quotes are literal JSON for the YAML template, not shell
    # quoting - envsubst drops this in as a flow-style list. Do not "fix" to an array.
    # shellcheck disable=SC2089
    CERT_DNS_NAMES="[\"${DOMAIN}\",\"git.${DOMAIN}\",\"grafana.${DOMAIN}\"]"
    CERT_IP_ADDRESSES='[]'
    ;;
  *)
    die "TLS_MODE must be selfsigned, staging or production - got '$TLS_MODE'"
    ;;
esac

log "TLS_MODE=$TLS_MODE  issuer=$CERT_ISSUER  host=$(platform_host)"

# ---------------------------------------------------------------------------
# 2. cert-manager
# ---------------------------------------------------------------------------
"$REPO_ROOT/scripts/cert-manager-install.sh"

# ---------------------------------------------------------------------------
# 3. Apply the issuer for this mode.
#    All three files ship in the repo; only the selected one is applied, so a
#    domainless cluster never creates an ACME account it cannot use.
# ---------------------------------------------------------------------------
mkdir -p "$RENDER_DIR"

case "$TLS_MODE" in
  selfsigned)
    kubectl apply -f "$CM_DIR/clusterissuer-selfsigned.yaml"
    log "Waiting for the local CA to be issued..."
    kubectl -n cert-manager wait --for=condition=Ready certificate/backbone-ca --timeout=90s \
      || die "the self-signed CA never became Ready.
  Check: kubectl -n cert-manager describe certificate backbone-ca"
    ;;
  staging)
    export ACME_EMAIL
    render_template "$CM_DIR/clusterissuer-staging.yaml" "$RENDER_DIR/issuer.yaml" 'ACME_EMAIL'
    kubectl apply -f "$RENDER_DIR/issuer.yaml"
    ;;
  production)
    export ACME_EMAIL
    render_template "$CM_DIR/clusterissuer-prod.yaml" "$RENDER_DIR/issuer.yaml" 'ACME_EMAIL'
    kubectl apply -f "$RENDER_DIR/issuer.yaml"
    ;;
esac

log "Waiting for ClusterIssuer/$CERT_ISSUER to be Ready..."
for _ in $(seq 1 45); do
  ready=$(kubectl get clusterissuer "$CERT_ISSUER" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ "$ready" = "True" ] && break
  sleep 2
done
[ "${ready:-}" = "True" ] || die "ClusterIssuer/$CERT_ISSUER not Ready after 90s.
  Check: kubectl describe clusterissuer $CERT_ISSUER"
ok "ClusterIssuer/$CERT_ISSUER Ready"

# ---------------------------------------------------------------------------
# 4. Kong declarative config, including the ACME challenge route.
#
#    Kong is DB-less and ignores Ingress, so cert-manager's HTTP-01 solver is
#    unreachable unless Kong is explicitly told to route to it. The route must
#    also stay OFF the https-redirect, or the ACME client follows a 301 it will
#    not accept and the order fails. This is why the route is added even in
#    selfsigned mode - so a later switch to ACME cannot deadlock.
# ---------------------------------------------------------------------------
ACME_SOLVER_ROUTE=$(cat <<'SOLVER'
      # cert-manager HTTP-01 solver. Deliberately http-only and NOT redirected:
      # ACME validation must be answerable over plain HTTP.
      - name: acme-solver-service
        url: http://cm-acme-http-solver.platform.svc:8089
        routes:
          - name: acme-solver-route
            paths:
              - /.well-known/acme-challenge
            strip_path: false
            protocols:
              - http

SOLVER
)
export ACME_SOLVER_ROUTE

render_template "k8s/platform/kong/tls.yaml" "$RENDER_DIR/kong-config.yaml" 'ACME_SOLVER_ROUTE'
kubectl apply -f "$RENDER_DIR/kong-config.yaml"
ok "Kong declarative config updated (TLS routes + acme-challenge + prometheus plugin)"

# ---------------------------------------------------------------------------
# 5. Certificate. Same object and same secretName in every mode.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2090  # literal JSON payloads for envsubst, see above
export CERT_ISSUER CERT_COMMON_NAME CERT_DNS_NAMES CERT_IP_ADDRESSES
render_template "$CM_DIR/certificate.yaml" "$RENDER_DIR/certificate.yaml" \
  'CERT_ISSUER CERT_COMMON_NAME CERT_DNS_NAMES CERT_IP_ADDRESSES'

# On a mode switch the existing Certificate has a different issuerRef. Patching
# issuerRef in place is allowed and triggers reissuance into the same secret -
# that is exactly the plug-and-play path, so apply (not delete+create) is right.
kubectl apply -f "$RENDER_DIR/certificate.yaml"

log "Waiting for certificate issuance (ACME can take ~2 min)..."
if ! kubectl -n platform wait --for=condition=Ready certificate/backbone-tls --timeout=240s; then
  kubectl -n platform describe certificate backbone-tls >&2 || true
  die "certificate was not issued.
  Common causes:
   - TLS_MODE=staging/production but DOMAIN does not resolve to ${NODE_IP}
   - port 80 not reachable from the internet (HTTP-01 validation)
   - the acme-challenge route is being redirected to https (must stay plain HTTP)
  Inspect: kubectl -n platform describe certificate backbone-tls
           kubectl -n platform get challenges"
fi
ok "Certificate issued into secret/kong-tls-cert"

# ---------------------------------------------------------------------------
# 6. Turn on Kong's TLS listener, now that the cert exists.
#    Done as a patch rather than in the committed Deployment so that a cluster
#    which has never run Phase 5A still starts Kong (an ssl listener with no
#    cert makes Kong refuse to boot).
# ---------------------------------------------------------------------------
kubectl -n platform set env deployment/kong \
  KONG_PROXY_LISTEN="0.0.0.0:8000, 0.0.0.0:8443 ssl" \
  KONG_SSL_CERT=/etc/secrets/kong-tls/tls.crt \
  KONG_SSL_CERT_KEY=/etc/secrets/kong-tls/tls.key >/dev/null

# Kong does not watch the secret - a reissued cert only takes effect on restart.
# This is also what picks up a mode switch.
kubectl -n platform rollout restart deployment/kong
kubectl -n platform rollout status deployment/kong --timeout=180s \
  || die "Kong did not come back after enabling TLS.
  Check: kubectl -n platform logs deploy/kong --tail=50"

HTTPS_PORT="$(svc_nodeport platform kong-proxy proxy-ssl)"
HOST="$(platform_host)"

ok "HTTPS live at https://${HOST}:${HTTPS_PORT}/"
log ""
if [ "$TLS_MODE" = selfsigned ]; then
  log "Self-signed: browsers will warn, and curl needs -k. That is expected."
  log "To adopt a real domain later - no rebuild, no manifest edits:"
  log "  1. point <domain> A record at ${NODE_IP}, open port 80 to the internet"
  log "  2. in .env:  DOMAIN=<domain>  ACME_EMAIL=<you>  TLS_MODE=staging"
  log "  3. make tls          # rehearse against the staging CA"
  log "  4. TLS_MODE=production && make tls"
fi
