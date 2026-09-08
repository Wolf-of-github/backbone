#!/usr/bin/env bash
# Generate htpasswd + self-signed TLS for the private registry and create the
# registry-auth / registry-tls secrets in the platform namespace. Idempotent.
# depends_on: [k8s/base/namespaces.yaml]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
require_vars REGISTRY_HOST REGISTRY_PORT REGISTRY_USER REGISTRY_PASS
need openssl
need kubectl
need htpasswd    # from apache2-utils / httpd-tools

WORK="$REPO_ROOT/.secrets"
mkdir -p "$WORK"
chmod 700 "$WORK"

HTPASSWD_FILE="$WORK/htpasswd"
TLS_KEY="$WORK/registry-tls.key"
TLS_CRT="$WORK/registry-tls.crt"

# --- htpasswd (bcrypt) -------------------------------------------------------
# -B bcrypt, -b batch (password as arg), -n write to stdout. Arg array: no shell
# string is built from the password.
htpasswd -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" > "$HTPASSWD_FILE"
chmod 600 "$HTPASSWD_FILE"
log "generated htpasswd for user '$REGISTRY_USER'"

# --- self-signed TLS with SANs --------------------------------------------------
# SAN covers both the configured host and localhost (for port-forward testing).
openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
  -keyout "$TLS_KEY" -out "$TLS_CRT" \
  -subj "/CN=${REGISTRY_HOST}" \
  -addext "subjectAltName=DNS:${REGISTRY_HOST},DNS:localhost,IP:127.0.0.1$( \
      [[ "$REGISTRY_HOST" =~ ^[0-9.]+$ ]] && printf ',IP:%s' "$REGISTRY_HOST" || true)"
chmod 600 "$TLS_KEY"
log "generated self-signed TLS cert for ${REGISTRY_HOST}"

# The registry cert is its own CA (self-signed); nodes trust it via registries.yaml.
cp "$TLS_CRT" "$WORK/registry-ca.crt"

# --- create/update secrets idempotently ------------------------------------
kubectl create secret generic registry-auth \
  --namespace platform \
  --from-file=htpasswd="$HTPASSWD_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls registry-tls \
  --namespace platform \
  --cert="$TLS_CRT" --key="$TLS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

ok "secrets registry-auth, registry-tls present in namespace platform"
