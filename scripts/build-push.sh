#!/usr/bin/env bash
# build-push.sh
# Purpose: Build and push ping + frontend Docker images to the registry
# depends_on: [.env.example, scripts/lib.sh]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need docker
need git

require_vars REGISTRY_URL

# Discover git SHA (short) for image tagging
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
log "Building images with tag: $GIT_SHA"

# Build and push each service
build_and_push() {
  local service=$1
  local service_dir="$REPO_ROOT/services/$service"

  [ -d "$service_dir" ] || die "Service directory not found: $service_dir"

  log "Building $service..."
  cd "$service_dir"

  docker build \
    -t "${REGISTRY_URL}/backbone-${service}:${GIT_SHA}" \
    -t "${REGISTRY_URL}/backbone-${service}:latest" \
    . || die "Docker build failed for $service"

  log "Pushing $service:$GIT_SHA..."
  docker push "${REGISTRY_URL}/backbone-${service}:${GIT_SHA}" || die "Docker push failed for $service:$GIT_SHA"

  log "Pushing $service:latest..."
  docker push "${REGISTRY_URL}/backbone-${service}:latest" || die "Docker push failed for $service:latest"

  ok "$service built and pushed"
}

# Build and push ping service
build_and_push "ping"

# Build and push frontend
build_and_push "frontend"

ok "All images built and pushed to $REGISTRY_URL"
