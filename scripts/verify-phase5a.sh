#!/usr/bin/env bash
# verify-phase5a.sh
# Purpose: Phase 5A gate (TLS). Asserts HTTPS terminates at Kong, HTTP redirects,
#          and the chain matches whatever TLS_MODE is set - a domainless cluster
#          must PASS here, not be skipped.
# depends_on: [scripts/bootstrap-tls.sh]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need curl
need jq
need openssl

fail() { die "verify-phase5a: $*"; }

TLS_MODE="${TLS_MODE:-selfsigned}"
NODE_IP="$(node_ip)"
HTTPS_PORT="$(svc_nodeport platform kong-proxy proxy-ssl)"
HTTP_PORT="$(svc_nodeport platform kong-proxy proxy)"
[ -n "$HTTPS_PORT" ] || fail "kong-proxy has no 'proxy-ssl' port - run 'make tls' first"

# Always connect to the node IP; use the domain (when there is one) only as the
# TLS SNI/Host, so the test does not depend on the operator's DNS resolver.
SNI_HOST="$(platform_host)"
CURL_RESOLVE=()
if has_real_domain; then
  CURL_RESOLVE=(--resolve "${SNI_HOST}:${HTTPS_PORT}:${NODE_IP}")
fi

log "Phase 5A verification (TLS_MODE=$TLS_MODE, host=$SNI_HOST, node=$NODE_IP)"

# [1/7] cert-manager healthy
log "[1/7] cert-manager"
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  avail=$(kubectl -n cert-manager get deploy "$d" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
  [ "${avail:-0}" -ge 1 ] || fail "cert-manager deployment/$d is not Available"
done
kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 \
  || fail "cert-manager CRDs missing"
ok "cert-manager Deployments Available, CRDs present"

# [2/7] the issuer for THIS mode is Ready
log "[2/7] ClusterIssuer for TLS_MODE=$TLS_MODE"
case "$TLS_MODE" in
  selfsigned) EXPECT_ISSUER="backbone-selfsigned" ;;
  staging)    EXPECT_ISSUER="backbone-staging" ;;
  production) EXPECT_ISSUER="backbone-prod" ;;
  *)          fail "unknown TLS_MODE '$TLS_MODE'" ;;
esac
issuer_ready=$(kubectl get clusterissuer "$EXPECT_ISSUER" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$issuer_ready" = "True" ] || fail "ClusterIssuer/$EXPECT_ISSUER is not Ready"
ok "ClusterIssuer/$EXPECT_ISSUER Ready"

# [3/7] certificate issued into the fixed secret name
log "[3/7] Certificate and kong-tls-cert secret"
cert_ready=$(kubectl -n platform get certificate backbone-tls \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$cert_ready" = "True" ] || fail "Certificate/backbone-tls is not Ready"

# The issuerRef must match the mode - this is what proves a mode switch actually
# took effect rather than leaving a stale cert from the previous issuer.
actual_issuer=$(kubectl -n platform get certificate backbone-tls -o jsonpath='{.spec.issuerRef.name}')
[ "$actual_issuer" = "$EXPECT_ISSUER" ] \
  || fail "Certificate points at issuer '$actual_issuer' but TLS_MODE=$TLS_MODE expects '$EXPECT_ISSUER' - re-run 'make tls'"

for key in tls.crt tls.key; do
  kubectl -n platform get secret kong-tls-cert -o jsonpath="{.data.$key}" 2>/dev/null | grep -q . \
    || fail "secret/kong-tls-cert is missing $key"
done
ok "Certificate Ready (issuer $EXPECT_ISSUER); secret/kong-tls-cert has tls.crt + tls.key"

# [4/7] HTTPS actually serves the API
log "[4/7] HTTPS through Kong"
code=$(curl -sk -o /dev/null -w '%{http_code}' "${CURL_RESOLVE[@]}" \
  "https://${SNI_HOST}:${HTTPS_PORT}/api/ping" || true)
# /api/ping is auth-protected since Phase 3, so 401 is a fully successful TLS
# termination. Anything that is not a real HTTP response means TLS is broken.
case "$code" in
  200|401) ok "HTTPS serves /api/ping (HTTP $code - 401 expected, route is auth-protected)" ;;
  000)     fail "no TLS response on :$HTTPS_PORT - is Kong's ssl listener up? kubectl -n platform logs deploy/kong" ;;
  *)       fail "unexpected status $code from https://${SNI_HOST}:${HTTPS_PORT}/api/ping" ;;
esac

# [5/7] plain HTTP redirects to HTTPS
log "[5/7] HTTP -> HTTPS redirect"
redirect=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' \
  "http://${NODE_IP}:${HTTP_PORT}/" || true)
echo "$redirect" | grep -qE '^30[128] https://' \
  || fail "http://${NODE_IP}:${HTTP_PORT}/ did not redirect to https (got: $redirect)"
ok "HTTP 301-redirects to HTTPS"

# [6/7] the chain matches the mode
log "[6/7] certificate chain for TLS_MODE=$TLS_MODE"
chain=$(echo | openssl s_client -connect "${NODE_IP}:${HTTPS_PORT}" \
  -servername "$SNI_HOST" 2>/dev/null | openssl x509 -noout -issuer -subject 2>/dev/null || true)
[ -n "$chain" ] || fail "could not read the served certificate with openssl s_client"

case "$TLS_MODE" in
  selfsigned)
    echo "$chain" | grep -qi 'backbone-local-ca' \
      || fail "expected the self-signed backbone CA as issuer, got: $chain"
    ok "self-signed chain served by the local backbone CA (untrusted by design)"
    ;;
  staging)
    echo "$chain" | grep -qi 'STAGING' \
      || fail "expected a Let's Encrypt STAGING issuer, got: $chain"
    ok "Let's Encrypt staging chain served"
    ;;
  production)
    echo "$chain" | grep -qiE "let's encrypt|letsencrypt" \
      || fail "expected a Let's Encrypt issuer, got: $chain"
    # The real test of production: trust works WITHOUT -k.
    trusted=$(curl -s -o /dev/null -w '%{http_code}' "${CURL_RESOLVE[@]}" \
      "https://${SNI_HOST}:${HTTPS_PORT}/api/ping" || true)
    case "$trusted" in
      200|401) ok "Let's Encrypt chain is publicly trusted (verified without -k)" ;;
      *)       fail "production cert is not trusted by the system CA bundle (status $trusted)" ;;
    esac
    ;;
esac

# [7/7] the acme-challenge path stays plain HTTP
# This is what keeps a FUTURE domain swap from deadlocking: if this path were
# redirected to https, ACME HTTP-01 validation could never complete.
log "[7/7] acme-challenge path is not redirected"
acme_code=$(curl -s -o /dev/null -w '%{http_code}' \
  "http://${NODE_IP}:${HTTP_PORT}/.well-known/acme-challenge/probe" || true)
case "$acme_code" in
  30[128]) fail "acme-challenge is being redirected to https - a future TLS_MODE switch to staging/production would fail validation" ;;
  000)     fail "no response on the acme-challenge path" ;;
  *)       ok "acme-challenge answers over plain HTTP (status $acme_code, no redirect)" ;;
esac

log ""
ok "PHASE 5A OK"
