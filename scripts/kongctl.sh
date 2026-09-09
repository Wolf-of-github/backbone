#!/usr/bin/env bash
# kongctl.sh
# Purpose: Wrapper around Kong Admin API (reload, routes, health)
# depends_on: [scripts/lib.sh, k8s/platform/kong/admin-service.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

need kubectl
need curl

KONG_ADMIN_URL="http://kong-admin.platform.svc:8001"

# Execute curl against Kong Admin API from within the cluster
kong_curl() {
  local path="$1"
  shift
  kubectl run kong-curl-temp --rm -i --restart=Never --image=curlimages/curl:latest -- \
    curl -sf "$KONG_ADMIN_URL$path" "$@" 2>/dev/null || die "Kong Admin API request failed: $path"
}

# Health check
health() {
  log "Checking Kong health..."
  local status
  status=$(kong_curl "/status" | grep -o '"database":{"reachable":[^}]*}')
  ok "Kong status: $status"
}

# List routes
routes() {
  log "Listing Kong routes..."
  local routes_json
  routes_json=$(kong_curl "/routes")

  echo "$routes_json" | grep -o '"name":"[^"]*"' | sed 's/"name":"/  - /' | sed 's/"$//' || die "Failed to parse routes"
  ok "Routes listed"
}

# Reload declarative config
reload() {
  log "Reloading Kong declarative config..."
  log "Note: In DB-less mode, Kong auto-reloads from the ConfigMap on pod restart"
  log "To apply config changes, run: kubectl rollout restart -n platform deployment/kong"
  ok "Reload instructions displayed"
}

# Main CLI
cmd="${1:-}"
case "$cmd" in
  health)
    health
    ;;
  routes)
    routes
    ;;
  reload)
    reload
    ;;
  *)
    echo "Usage: kongctl.sh {health|routes|reload}"
    echo ""
    echo "  health  - Check Kong health status"
    echo "  routes  - List all configured routes"
    echo "  reload  - Display instructions for reloading config"
    exit 1
    ;;
esac
