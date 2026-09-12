#!/usr/bin/env bash
# setup-env.sh
# Purpose: interactive one-time wizard that builds .env for the whole install.
#          Asks every question up front so `make backbone` can then run every
#          phase unattended - nothing later prompts, and nothing is ever
#          hand-edited into the file.
# depends_on: [.env.example]
#
# Passwords are never printed back or echoed while typing. Anything this
# script can safely generate (DB/JWT-adjacent passwords, Grafana admin
# password), it offers to generate - press Enter to accept, or type your own.
# Registry and S3 credentials cannot be generated - they come from an account
# you control - so this script prompts for them but never invents one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '  %s\n' "$*" >&2; }
ok()   { printf '  \033[32mOK\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[ -f .env ] || cp .env.example .env

# Same rule scripts/lib.sh uses for "is there a real domain" - duplicated
# (rather than sourcing lib.sh) because lib.sh's load_env would require every
# variable this wizard is still in the middle of filling in.
has_real_domain() {
  [ -n "${1:-}" ] && [ "$1" != "backbone.local" ] && [ "$1" != "localhost" ]
}

# Set KEY=VALUE in .env, escaping for sed's replacement side (& and | and \).
set_env() {
  local key="$1" value="$2" escaped
  escaped=$(printf '%s' "$value" | sed -e 's/[&|\]/\\&/g')
  if grep -q "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${escaped}|" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

current_value() { grep "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2-; }

# Prompt for a plain (non-secret) value. Shows the current/default and keeps
# it on a bare Enter.
ask() {
  local key="$1" prompt="$2" default="$3" reply
  local existing; existing="$(current_value "$key")"
  [ -n "$existing" ] && default="$existing"
  read -r -p "  $prompt [$default]: " reply
  set_env "$key" "${reply:-$default}"
}

# Prompt for a secret. Enter alone means "generate one" - never leaves it
# blank. Input is hidden; nothing is echoed back, ever.
ask_secret() {
  local key="$1" prompt="$2" generator="$3" reply
  local existing; existing="$(current_value "$key")"
  if [ -n "$existing" ]; then
    read -r -p "  $prompt (already set - press Enter to keep, or type a new value): " -s reply
    echo >&2
    [ -n "$reply" ] && set_env "$key" "$reply"
    return
  fi
  read -r -p "  $prompt (press Enter to auto-generate): " -s reply
  echo >&2
  if [ -z "$reply" ]; then
    reply="$(eval "$generator")"
    ok "$key generated"
  fi
  set_env "$key" "$reply"
}

ask_yesno() {
  local prompt="$1" default="$2" reply
  read -r -p "  $prompt [${default}]: " reply
  reply="${reply:-$default}"
  case "$reply" in
    y|Y|yes|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

echo "" >&2
echo "backbone setup - answer these once; every phase after this runs unattended." >&2
echo "" >&2

# --- Cluster address ---------------------------------------------------------
log "Cluster address"
MY_IP="$(hostname -I | awk '{print $1}')"
ask K3S_SERVER_ADDR "This node's address (workers dial this)" "$MY_IP"

# --- Container registry (Phase 2) --------------------------------------------
echo "" >&2
log "Container registry - where built images are pushed (Phase 2)"
log "Needs an account you already have on Docker Hub or GHCR."
ask REGISTRY_URL "Registry URL - docker.io/<your-username> or ghcr.io/<your-username>" ""
require_registry="$(current_value REGISTRY_URL)"
[ -n "$require_registry" ] || die "REGISTRY_URL cannot be blank - create a Docker Hub or GHCR account first"

# A bare username with no '/' is a common mistake here - assume Docker Hub
# rather than silently trying to "docker login" to a host that doesn't exist.
if [[ "$require_registry" != */* ]]; then
  log "'$require_registry' has no registry host - assuming Docker Hub: docker.io/$require_registry"
  require_registry="docker.io/$require_registry"
  set_env REGISTRY_URL "$require_registry"
fi

if ask_yesno "Log in to this registry now? (needed before Phase 2 builds/pushes images) [Y/n]" "Y"; then
  default_user="${require_registry#*/}"
  read -r -p "  Registry username (same as in the URL above) [$default_user]: " REG_USER
  REG_USER="${REG_USER:-$default_user}"
  read -r -p "  Registry access token/password (hidden): " -s REG_TOKEN
  echo >&2
  registry_host="${require_registry%%/*}"
  if printf '%s' "$REG_TOKEN" | docker login "$registry_host" -u "$REG_USER" --password-stdin; then
    ok "docker login succeeded"
  else
    die "docker login failed - re-run 'make setup' or 'docker login' by hand once you have working credentials"
  fi
  unset REG_TOKEN
else
  log "Skipped - run 'docker login' yourself before Phase 2."
fi

# --- Data layer (Phase 1) ----------------------------------------------------
echo "" >&2
log "Database credentials (Phase 1) - press Enter on any of these to auto-generate"
ask_secret MONGO_ROOT_PASSWORD "MongoDB root password"        "openssl rand -base64 24"
ask_secret MONGO_APP_PASSWORD  "MongoDB app-user password"     "openssl rand -base64 24"
ask_secret REDIS_PASSWORD      "Redis password"                "openssl rand -base64 24"
log "Save these somewhere safe (e.g. a password manager) - nothing prints them again."

# --- Auth (Phase 3) -----------------------------------------------------------
# FRONTEND_URL depends on Kong's port, which depends on TLS_MODE below - filled
# in after that's known.

# --- TLS (Phase 5A) -----------------------------------------------------------
echo "" >&2
log "HTTPS (Phase 5A)"
if ask_yesno "Do you have a real domain pointed at this instance? [y/N]" "N"; then
  ask DOMAIN "Domain name" "backbone.local"
  ask ACME_EMAIL "Email for Let's Encrypt expiry notices" ""
  set_env TLS_MODE staging
  log "Set to 'staging' (rehearsal). Change TLS_MODE to 'production' yourself once staging works."
else
  set_env TLS_MODE selfsigned
  log "Using a self-signed certificate on the node IP - no domain needed. Browsers will warn; the encryption is real."
fi

if has_real_domain "$(current_value DOMAIN)"; then
  FRONTEND_URL="https://$(current_value DOMAIN)"
else
  FRONTEND_URL="https://${MY_IP}:30443"
fi
set_env FRONTEND_URL "$FRONTEND_URL"

# --- Observability (Phase 5B) -------------------------------------------------
echo "" >&2
log "Observability / Grafana (Phase 5B)"
ask_secret GRAFANA_ADMIN_PASSWORD "Grafana admin password" "openssl rand -base64 24"

# --- Backup / DR (Phase 6A) ---------------------------------------------------
echo "" >&2
log "Backups (Phase 6A) - needs a real S3-compatible bucket you already created."
log "(IAM user scoped to just that bucket; see the guide if you haven't made one yet.)"
if ask_yesno "Set up backups now? [Y/n]" "Y"; then
  ask BACKUP_S3_BUCKET  "S3 bucket name" ""
  ask BACKUP_S3_REGION  "S3 region"      "us-east-1"
  ask BACKUP_S3_ENDPOINT "S3 endpoint (blank = AWS S3; set for B2/R2/MinIO)" ""
  read -r -p "  S3 access key ID: " BACKUP_S3_ACCESS_KEY_VAL
  [ -n "$BACKUP_S3_ACCESS_KEY_VAL" ] || die "an S3 access key is required to set up backups now - re-run and paste a real key, or answer 'n' to skip"
  set_env BACKUP_S3_ACCESS_KEY "$BACKUP_S3_ACCESS_KEY_VAL"
  unset BACKUP_S3_ACCESS_KEY_VAL
  read -r -p "  S3 secret access key (hidden): " -s BACKUP_S3_SECRET_KEY_VAL
  echo >&2
  [ -n "$BACKUP_S3_SECRET_KEY_VAL" ] || die "an S3 secret key is required to set up backups now - re-run and paste a real key, or answer 'n' to skip"
  set_env BACKUP_S3_SECRET_KEY "$BACKUP_S3_SECRET_KEY_VAL"
  unset BACKUP_S3_SECRET_KEY_VAL
else
  set_env BACKUP_S3_BUCKET ""
  log "Skipped - 'make backbone' will skip Phase 6A (backups) entirely."
  log "Run 'make setup' again any time to add a bucket, then 'make phase6a'."
fi

# --- Maintenance mode (Phase 6B) ---------------------------------------------
echo "" >&2
log "Maintenance mode (Phase 6B)"
ask ADMIN_EMAIL "Email to promote to admin once auth is up (for the maintenance off-switch)" "admin@example.com"

echo "" >&2
ok "Setup complete - .env is ready."
log "Next: make backbone"
