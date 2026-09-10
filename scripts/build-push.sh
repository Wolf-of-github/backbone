#!/usr/bin/env bash
# build-push.sh
# Purpose: Build and push service images to the active registry.
# depends_on: [.env.example, scripts/lib.sh]
#
# usage: build-push.sh [service ...]     (default: every service)
#
# The destination comes from registry_prefix() in lib.sh, which resolves
# REGISTRY_MODE (external -> REGISTRY_URL, incluster -> the Gitea registry from
# Phase 5C). That indirection is what makes the registry cutover one .env
# variable instead of an edit to every deployment and script.

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

log "Registry: $REGISTRY  (REGISTRY_MODE=${REGISTRY_MODE:-external})"
log "Tag:      $GIT_SHA"

# Log in when pushing to the in-cluster registry - it is authenticated, and a
# push without credentials fails with an opaque 401.
if [ "${REGISTRY_MODE:-external}" = "incluster" ]; then
  require_vars GITEA_ADMIN_USER GITEA_ADMIN_PASSWORD
  log "Authenticating to the in-cluster registry..."
  printf '%s' "$GITEA_ADMIN_PASSWORD" \
    | docker login "gitea-http.ci.svc:3000" -u "$GITEA_ADMIN_USER" --password-stdin >/dev/null 2>&1 \
    || die "docker login to the in-cluster registry failed.
  The registry is a ClusterIP Service, so it is not reachable from outside the
  cluster by that name. Either build from a node with it in /etc/hosts, or push
  through Kong at https://<host>/git, or let CI build in-cluster (ci/.drone.example.yml)."
fi

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
  docker build \
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
