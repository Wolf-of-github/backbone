#!/usr/bin/env bash
# build-push.sh
# Purpose: Build and push service images to the active registry.
# depends_on: [.env.example, scripts/lib.sh]
#
# usage: build-push.sh [service ...]     (default: every service)
#
# The destination comes from REGISTRY_URL via registry_prefix() in lib.sh -
# that indirection is what lets every deployment and script resolve the
# registry through one place instead of hardcoding it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

load_env
need docker
need git

REGISTRY="$(registry_prefix)"
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")

# Every service with a Dockerfile. jobs-api and worker arrived in Phase 4 but
# were never added here, so `make build-push` silently skipped them.
ALL_SERVICES=(ping frontend auth jobs-api worker)

if [ "$#" -gt 0 ]; then
  SERVICES=("$@")
else
  SERVICES=("${ALL_SERVICES[@]}")
fi

log "Registry: $REGISTRY"
log "Tag:      $GIT_SHA"

build_and_push() {
  local service="$1"
  local service_dir="$REPO_ROOT/services/$service"

  [ -d "$service_dir" ] || die "no such service: $service_dir"

  local dockerfile="$service_dir/Dockerfile"
  [ -f "$dockerfile" ] || die "no Dockerfile for $service"

  # Build context differs per service and must match how each Dockerfile was
  # written - getting it wrong fails with a confusing "file not found" on a
  # COPY. Everything that copies services/common needs the repo root; only the
  # frontend is self-contained (it is a static SPA with no shared modules).
  #   repo root:   ping, auth, jobs-api, worker   (COPY services/...)
  #   service dir: frontend                       (COPY . .)
  local context
  case "$service" in
    frontend) context="$service_dir" ;;
    *)        context="$REPO_ROOT" ;;
  esac

  log "Building $service (context: ${context#"$REPO_ROOT"/})..."
  # --no-cache: the legacy Docker builder has been observed reusing a stale
  # COPY layer even when the copied source changed (HANDOFF.md documents
  # this for Phase 6B's auth image, and it recurred independently on Phase
  # 4's jobs-api build) - it fails silently, reporting a successful build
  # of stale code, which is worse than the extra build time costs.
  docker build --no-cache \
    -f "$dockerfile" \
    -t "${REGISTRY}/backbone-${service}:${GIT_SHA}" \
    -t "${REGISTRY}/backbone-${service}:latest" \
    "$context" || die "docker build failed for $service"

  log "Pushing $service..."
  docker push "${REGISTRY}/backbone-${service}:${GIT_SHA}" || die "docker push failed for $service:${GIT_SHA}"
  docker push "${REGISTRY}/backbone-${service}:latest"     || die "docker push failed for $service:latest"

  ok "$service -> ${REGISTRY}/backbone-${service}:${GIT_SHA}"
}

for svc in "${SERVICES[@]}"; do
  build_and_push "$svc"
done

ok "built and pushed: ${SERVICES[*]}"
