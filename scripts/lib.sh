#!/usr/bin/env bash
# Shared helpers for Phase 0 scripts. Sourced, not executed.
# depends_on: []

# Repo root = parent of this script's directory.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# KUBECONFIG defaults to the repo-local one written by scripts/cluster-up.sh.
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig}"

log()  { printf '  %s\n' "$*" >&2; }
ok()   { printf '  \033[32mOK\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# Load .env into the environment. Exits if it is missing.
load_env() {
  local env_file="$REPO_ROOT/.env"
  [ -f "$env_file" ] || die "missing $env_file - run: cp .env.example .env && edit it"
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

# Require a set of variables to be non-empty.
require_vars() {
  local v missing=()
  for v in "$@"; do
    [ -n "${!v:-}" ] || missing+=("$v")
  done
  [ ${#missing[@]} -eq 0 ] || die ".env is missing required values: ${missing[*]}"
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Percent-encode a string for safe use inside a mongodb:// URI userinfo
# segment (username or password). MONGO_*_PASSWORD values come from
# `openssl rand -base64`, which routinely produces '+' and '/' - both are
# URI-significant and break MongoDB's connection-string parser if not
# escaped ("Password contains unescaped characters").
urlencode() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# --- Phase 5 helpers ---------------------------------------------------------

# IP of the first Ready node. Verification and bootstrap scripts address the
# cluster through this; skipping NotReady nodes matters on a partial cluster.
node_ip() {
  kubectl get nodes -o json \
    | jq -r '.items[]
             | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))
             | .status.addresses[]
             | select(.type=="InternalIP" or .type=="ExternalIP") | .address' \
    | head -1
}

# NodePort currently assigned to a port of a Service: svc_nodeport <ns> <svc> <portname>
svc_nodeport() {
  kubectl -n "$1" get svc "$2" \
    -o jsonpath="{.spec.ports[?(@.name=='$3')].nodePort}"
}

# True when DOMAIN is a real, routable name rather than the "no domain" default.
# Everything domain-shaped (host routes, ACME) keys off this, so a domainless
# cluster silently gets the path-based equivalents instead of broken host routes.
has_real_domain() {
  [ -n "${DOMAIN:-}" ] && [ "$DOMAIN" != "backbone.local" ] && [ "$DOMAIN" != "localhost" ]
}

# Host that serves the platform: the domain when there is one, else the node IP.
platform_host() {
  if has_real_domain; then printf '%s' "$DOMAIN"; else node_ip; fi
}

# Registry that image names are built from and pulled from. build-push.sh
# and every bootstrap script resolve images through this one function.
registry_prefix() {
  [ -n "${REGISTRY_URL:-}" ] || die "REGISTRY_URL is blank in .env"
  printf '%s' "$REGISTRY_URL"
}

# Insert a block of YAML into Kong's declarative config, immediately before the
# top-level `plugins:` key (or appended when there is none), and write the
# result back to the kong-declarative-config ConfigMap.
#
# Kong DB-less loads exactly ONE declarative file, so new routes have to be
# merged into the live config rather than applied as a second manifest.
#
# Implemented with a while-read loop rather than `awk -v`: BSD/macOS awk
# rejects embedded newlines in a -v assignment ("newline in string"), so the
# awk form silently failed to inject anything on a macOS control host.
#
# usage: kong_insert_block <marker-service-name> <yaml-block>
#        returns 1 (and changes nothing) if the marker is already present
kong_insert_block() {
  local marker="$1" block="$2"
  local current updated inserted=0 line

  current=$(kubectl -n platform get configmap kong-declarative-config \
    -o jsonpath='{.data.kong\.yaml}') || die "could not read the Kong config"

  if printf '%s' "$current" | grep -q "name: $marker"; then
    return 1
  fi

  # `plugins:` is a TOP-LEVEL key of kong.yaml, at column 0 - the 4-space indent
  # it has inside the ConfigMap manifest belongs to the YAML block scalar and is
  # stripped when Kong (or kubectl) reads the value out. Matching the indented
  # form here silently never fires, appending routes at the wrong depth.
  updated=""
  while IFS= read -r line; do
    if [ "$inserted" -eq 0 ] && printf '%s' "$line" | grep -q '^plugins:'; then
      updated+="$block"$'\n'
      inserted=1
    fi
    updated+="$line"$'\n'
  done <<< "$current"

  [ "$inserted" -eq 1 ] || updated+="$block"$'\n'

  kubectl -n platform create configmap kong-declarative-config \
    --from-literal=kong.yaml="$updated" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Render a template to .rendered/, substituting only the named vars. Uses
# envsubst with an explicit allowlist so that '$' in the manifest body (shell
# snippets, Prometheus $labels, Grafana $__rate_interval) survives untouched.
# usage: render_template <src> <dst> 'VAR1 VAR2 ...'
render_template() {
  local src="$1" dst="$2" vars="$3" list=""
  local v
  for v in $vars; do list+="\${$v}"; done
  mkdir -p "$(dirname "$dst")"
  envsubst "$list" < "$src" > "$dst"
}
