#!/usr/bin/env bash
# verify-phase5.sh
# Purpose: The Phase 5 gate - runs both track gates in order.
# depends_on: [verify-phase5a.sh, verify-phase5b.sh]
#
# Order matters: 5B's cert-expiry alert reads cert-manager metrics from 5A. A
# failure in 5A usually explains a failure in 5B, so this stops at the first
# failing gate rather than reporting two failures with one cause.
#
# 5C (CI/CD + in-cluster registry) is not on this branch - deferred by
# choice; see HANDOFF.md and the phase-5c-cicd branch.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

log "===================================================="
log " Phase 5 - Operate: running both track gates"
log "===================================================="
log ""

log "--- Track A: TLS ---"
"$REPO_ROOT/scripts/verify-phase5a.sh" || die "Phase 5A failed - fix TLS before the later track"
log ""

log "--- Track B: Observability ---"
"$REPO_ROOT/scripts/verify-phase5b.sh" || die "Phase 5B failed"
log ""

log "===================================================="
ok "PHASE 5 OK"
log "===================================================="
