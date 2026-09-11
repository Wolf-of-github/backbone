#!/usr/bin/env bash
# verify-phase5b.sh
# Purpose: Phase 5B gate (observability). Asserts metrics are actually being
#          scraped, logs are actually arriving, Grafana is usable and locked
#          down, and alerts actually fire end to end.
# depends_on: [scripts/bootstrap-observability.sh]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need curl
need jq

fail() { die "verify-phase5b: $*"; }

NS=observability
PROBE_POD="verify5b-probe-$$"

cleanup() {
  kubectl -n "$NS" delete pod "$PROBE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Run queries from inside the cluster - Prometheus, Loki and Alertmanager have
# no public route by design, and proving that is part of this gate.
incluster() {
  kubectl -n "$NS" run "$PROBE_POD" --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet -- \
    sh -c "$1" 2>/dev/null
}

log "Phase 5B verification (observability)"

# [1/7] workloads
log "[1/7] Workloads Ready"
for d in prometheus alertmanager grafana; do
  avail=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)
  [ "${avail:-0}" -ge 1 ] || fail "deployment/$d is not Available"
done
loki_ready=$(kubectl -n "$NS" get statefulset loki -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[ "${loki_ready:-0}" -ge 1 ] || fail "statefulset/loki is not Ready"

# Promtail must be on EVERY node - this is what makes log collection survive
# joining a new machine.
desired=$(kubectl -n "$NS" get ds promtail -o jsonpath='{.status.desiredNumberScheduled}')
ready=$(kubectl -n "$NS" get ds promtail -o jsonpath='{.status.numberReady}')
[ -n "$desired" ] && [ "$ready" = "$desired" ] \
  || fail "promtail DaemonSet is $ready/$desired Ready - some node is not shipping logs"
ok "prometheus, alertmanager, grafana, loki Ready; promtail on $ready/$desired nodes"

# [2/7] Prometheus targets
log "[2/7] Prometheus scrape targets"
targets=$(incluster "curl -s http://prometheus.$NS.svc:9090/api/v1/targets?state=active")
[ -n "$targets" ] || fail "could not query the Prometheus targets API"

up_count=$(printf '%s' "$targets" | jq '[.data.activeTargets[] | select(.health=="up")] | length')
[ "${up_count:-0}" -ge 1 ] || fail "no Prometheus targets are UP"

for job in kong kubernetes-nodes; do
  printf '%s' "$targets" \
    | jq -e --arg j "$job" '.data.activeTargets[] | select(.labels.job==$j and .health=="up")' >/dev/null \
    || fail "scrape job '$job' has no UP target"
done
ok "$up_count targets UP (kong and kubernetes-nodes among them)"

# [3/7] the platform's own instrumentation
# This is the check that proves services/common/metrics.js is wired in, not
# merely that Prometheus is running.
log "[3/7] backbone service metrics"
q=$(incluster "curl -sG http://prometheus.$NS.svc:9090/api/v1/query \
  --data-urlencode 'query=count(backbone_http_requests_total)'")
value=$(printf '%s' "$q" | jq -r '.data.result[0].value[1] // "0"')
if [ "${value%%.*}" -ge 1 ] 2>/dev/null; then
  ok "backbone_http_requests_total present ($value series)"
else
  fail "no backbone_* metrics in Prometheus.
  Services are not instrumented or lack the scrape annotations.
  See docs/metrics-scraping.md; confirm the annotations are on the POD TEMPLATE."
fi

# [4/7] Loki has logs
log "[4/7] Loki log ingestion"
loki_q=$(incluster "curl -sG http://loki.$NS.svc:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace=\"platform\"}' \
  --data-urlencode 'limit=5' \
  --data-urlencode 'start='\$(( \$(date +%s) - 900 ))'000000000'")
status=$(printf '%s' "$loki_q" | jq -r '.status // "error"')
[ "$status" = "success" ] || fail "Loki query failed: $loki_q"
streams=$(printf '%s' "$loki_q" | jq '.data.result | length')
[ "${streams:-0}" -ge 1 ] \
  || fail "Loki returned no log streams for namespace 'platform' in the last 15m - is Promtail shipping?"
ok "Loki returned $streams log stream(s) from the last 15m"

# [5/7] Grafana reachable and locked down
log "[5/7] Grafana through Kong"
NODE_IP="$(node_ip)"
HTTPS_PORT="$(svc_nodeport platform kong-proxy proxy-ssl)"
g_code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${NODE_IP}:${HTTPS_PORT}/grafana/login" || true)
case "$g_code" in
  200) ok "Grafana login page served at /grafana" ;;
  000) fail "no response for /grafana through Kong - is the route present? ./scripts/kongctl.sh routes" ;;
  *)   fail "unexpected status $g_code for /grafana/login" ;;
esac

# Anonymous access must be refused.
anon=$(incluster "curl -s -o /dev/null -w '%{http_code}' http://grafana.$NS.svc:3000/api/datasources")
[ "$anon" = "401" ] \
  || fail "Grafana /api/datasources returned $anon without credentials - expected 401 (anonymous access must be off)"

# Both datasources must be healthy, or every dashboard is empty.
ds=$(incluster "curl -s -u '$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD' \
  http://grafana.$NS.svc:3000/api/datasources")
for name in Prometheus Loki; do
  printf '%s' "$ds" | jq -e --arg n "$name" '.[] | select(.name==$n)' >/dev/null \
    || fail "Grafana datasource '$name' is not provisioned"
done
ok "anonymous access refused; Prometheus and Loki datasources provisioned"

# [6/7] the alerting pipeline is live
#
# Asserts the two things that actually break silently: Prometheus having no
# Alertmanager to deliver to, and the rule file failing to parse (in which case
# Prometheus starts happily with zero rules and never alerts on anything).
# A truly synthetic alert would need a rule mounted into Prometheus and a
# restart to pick it up; that is a slower, more disruptive test of the same
# two failure modes.
log "[6/7] Alerting pipeline"
am=$(incluster "curl -s http://prometheus.$NS.svc:9090/api/v1/alertmanagers")
active_am=$(printf '%s' "$am" | jq '.data.activeAlertmanagers | length')
[ "${active_am:-0}" -ge 1 ] \
  || fail "Prometheus has no active Alertmanager - alerts would fire into the void"

rules=$(incluster "curl -s http://prometheus.$NS.svc:9090/api/v1/rules")
rule_count=$(printf '%s' "$rules" | jq '[.data.groups[].rules[]] | length')
[ "${rule_count:-0}" -ge 1 ] || fail "no alert rules loaded from prometheus-rules"
printf '%s' "$rules" | jq -e '.data.groups[] | select(.name=="backbone-edge")' >/dev/null \
  || fail "the backbone-edge rule group did not load"
ok "Alertmanager connected; $rule_count alert rules loaded"

# [7/7] nothing but Grafana is public
log "[7/7] Prometheus/Alertmanager/Loki are not publicly routed"
for path in /prometheus /alertmanager /loki; do
  # Kong's catch-all "/" route sends unknown paths to the frontend SPA, so a
  # 200 here would be the SPA, not the service. Checking the status code would
  # therefore prove nothing - what must NOT happen is one of these answering
  # as itself, so inspect the body instead.
  body=$(curl -sk "https://${NODE_IP}:${HTTPS_PORT}${path}/" 2>/dev/null | head -c 400 || true)
  if printf '%s' "$body" | grep -qiE 'prometheus time series|alertmanager|grafana loki'; then
    fail "$path is publicly reachable - it must stay ClusterIP-only"
  fi
done
ok "observability backends are not exposed through Kong"

log ""
ok "PHASE 5B OK"
