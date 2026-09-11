#!/usr/bin/env bash
# apply-app-manifests.sh
# Purpose: Apply the k8s/app/* manifests with the image registry substituted in.
# depends_on: [scripts/lib.sh]
#
# usage: apply-app-manifests.sh [service ...]     (default: every service)
#
# WHY THIS EXISTS
# The k8s/app/*/deployment.yaml files are TEMPLATES: their image: line carries
# a registry placeholder. Running `kubectl apply -f k8s/app/<svc>/` directly
# sets the image to the literal placeholder and the pod fails with
# InvalidImageName - the old ReplicaSet keeps serving, so it looks like a
# stuck rollout rather than a bad image.
#
# Phases 2-4 each open-coded this substitution differently:
#   bootstrap-edge.sh   sed "s|\${REGISTRY_URL}|...|"  then piped to kubectl
#   bootstrap-jobs.sh   sed -i  (REWRITES THE TRACKED FILE IN PLACE)
# and the placeholders themselves were inconsistent - ${REGISTRY_URL} in
# ping/frontend, bare REGISTRY_URL in auth/jobs-api/worker. This script is the
# one place that knows how to do it, handles both spellings, and never writes
# to the tracked manifests.
#
# Images resolve through registry_prefix(), so REGISTRY_MODE=incluster works
# here too (Phase 5C).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl

REGISTRY="$(registry_prefix)"

ALL_SERVICES=(ping frontend auth jobs-api worker)
if [ "$#" -gt 0 ]; then
  SERVICES=("$@")
else
  SERVICES=("${ALL_SERVICES[@]}")
fi

log "Registry: $REGISTRY (REGISTRY_MODE=${REGISTRY_MODE:-external})"

for svc in "${SERVICES[@]}"; do
  dir="k8s/app/$svc"
  [ -d "$dir" ] || die "no manifests at $dir"

  for f in "$dir"/*.yaml; do
    [ -e "$f" ] || continue
    # Both placeholder spellings, and never in place - the tracked file keeps
    # its placeholder so the next run substitutes the then-current registry.
    sed -e "s|\${REGISTRY_URL}|${REGISTRY}|g" \
        -e "s|REGISTRY_URL|${REGISTRY}|g" \
        "$f" | kubectl apply -f - >/dev/null \
      || die "failed applying $f"
  done
  ok "applied $dir"
done

log ""
log "Rollouts (images are :latest with imagePullPolicy Always, so a restart"
log "is what actually pulls a rebuilt image):"
for svc in "${SERVICES[@]}"; do
  kubectl -n app get deploy "$svc" >/dev/null 2>&1 || continue
  kubectl -n app rollout status "deploy/$svc" --timeout=180s \
    || die "rollout failed for $svc.
  Inspect: kubectl -n app get pods -l app=$svc
           kubectl -n app logs -l app=$svc --tail=50"
done

ok "all app manifests applied and rolled out"
