#!/usr/bin/env bash
# promote-admin.sh
# Purpose: Phase 6B - register (if needed) and promote ADMIN_EMAIL to the
#          admin role, so the maintenance HTTP off-switch has an account
#          that can call it. Runs unattended as part of `make backbone`.
# depends_on: [services/auth (Phase 3), k8s/data/mongodb]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need curl
need jq

if [ -z "${ADMIN_EMAIL:-}" ]; then
  log "ADMIN_EMAIL is blank in .env - skipping admin promotion."
  log "Maintenance mode's HTTP off-switch will have no admin account. The"
  log "'./scripts/maintenance' CLI still works without one."
  exit 0
fi

NODE_IP="$(node_ip)"
HTTPS_PORT="$(svc_nodeport platform kong-proxy proxy-ssl 2>/dev/null || echo 30443)"
ENDPOINT="https://${NODE_IP}:${HTTPS_PORT}"

ADMIN_PASSWORD="$(openssl rand -base64 24)"

log "Registering ${ADMIN_EMAIL}..."
REGISTER_CODE=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "${ENDPOINT}/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}")

case "$REGISTER_CODE" in
  200|201)
    ok "registered ${ADMIN_EMAIL}"
    # Saved to .env (like every other credential this platform generates) so
    # it isn't lost if this terminal's scrollback is - printing it once and
    # never storing it anywhere was the earlier behavior, and it's exactly
    # what stranded the operator out of their own admin account.
    escaped_pw=$(printf '%s' "$ADMIN_PASSWORD" | sed -e 's/[&|\]/\\&/g')
    if grep -q '^ADMIN_PASSWORD=' "$REPO_ROOT/.env"; then
      sed -i.bak "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${escaped_pw}|" "$REPO_ROOT/.env" && rm -f "$REPO_ROOT/.env.bak"
    else
      printf 'ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD" >> "$REPO_ROOT/.env"
    fi
    log ""
    log "*** Password saved to .env as ADMIN_PASSWORD ***"
    log "  email:    ${ADMIN_EMAIL}"
    log "  password: ${ADMIN_PASSWORD}"
    log ""
    ;;
  409)
    log "${ADMIN_EMAIL} is already registered - promoting the existing account (its password is unchanged)."
    ;;
  *)
    die "could not register ${ADMIN_EMAIL} (HTTP ${REGISTER_CODE}) - is Phase 3 (auth) deployed?"
    ;;
esac

log "Promoting ${ADMIN_EMAIL} to admin..."
kubectl -n data exec -i statefulset/mongodb -- mongosh --quiet \
  "mongodb://$(urlencode "$MONGO_ROOT_USER"):$(urlencode "$MONGO_ROOT_PASSWORD")@localhost:27017/${MONGO_APP_DB:-backbone}?authSource=admin" \
  --eval "db.users.updateOne({email: \"${ADMIN_EMAIL}\"}, {\$addToSet: {roles: \"admin\"}})" >/dev/null \
  || die "could not promote ${ADMIN_EMAIL} - check MongoDB is up and the email is correct"

ok "${ADMIN_EMAIL} is now an admin"
