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
