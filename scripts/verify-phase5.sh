#!/usr/bin/env bash
# verify-phase5.sh
# Purpose: The Phase 5 gate - runs all three track gates in order.
# depends_on: [verify-phase5a.sh, verify-phase5b.sh, verify-phase5c.sh]
#
# Order matters: 5B's cert-expiry alert reads cert-manager metrics from 5A, and
# 5C is served over 5A's TLS listener. A failure in an earlier track usually
# explains the later ones, so this stops at the first failing gate rather than
# reporting three failures with one cause.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

log "===================================================="
log " Phase 5 - Operate: running all three track gates"
log "===================================================="
log ""

log "--- Track A: TLS ---"
"$REPO_ROOT/scripts/verify-phase5a.sh" || die "Phase 5A failed - fix TLS before the later tracks"
log ""

log "--- Track B: Observability ---"
"$REPO_ROOT/scripts/verify-phase5b.sh" || die "Phase 5B failed"
log ""

log "--- Track C: CI/CD + registry ---"
"$REPO_ROOT/scripts/verify-phase5c.sh" || die "Phase 5C failed"
log ""

log "===================================================="
ok "PHASE 5 OK"
log "===================================================="
