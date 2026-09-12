#!/usr/bin/env bash
# bootstrap-observability.sh
# Purpose: Phase 5B - stand up Prometheus, Alertmanager, Loki, Promtail and
#          Grafana, and route Grafana through Kong.
# depends_on: [scripts/lib.sh, k8s/observability/**]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl
need jq
need envsubst

RENDER_DIR="$REPO_ROOT/.rendered/observability"
OBS_DIR="k8s/observability"

kubectl get ns platform data app >/dev/null 2>&1 \
  || die "core namespaces missing - run 'make base' first"

kubectl create namespace observability \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace observability backbone.dev/tier=observability --overwrite >/dev/null

require_vars GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD

: "${PROM_RETENTION:=15d}"
: "${LOKI_RETENTION:=168h}"
: "${CLUSTER_NAME:=backbone}"

mkdir -p "$RENDER_DIR"

# ---------------------------------------------------------------------------
# 1. Grafana admin credentials. Idempotent create-or-update, values never echoed
#    (the create-secrets.sh convention from Phase 0).
# ---------------------------------------------------------------------------
log "Creating grafana-admin secret..."
kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user="$GRAFANA_ADMIN_USER" \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "secret/grafana-admin"

# ---------------------------------------------------------------------------
# 2. Prometheus
# ---------------------------------------------------------------------------
log "Applying Prometheus..."
kubectl apply -f "$OBS_DIR/prometheus/rbac.yaml"

export CLUSTER_NAME PROM_RETENTION
render_template "$OBS_DIR/prometheus/configmap.yaml" \
  "$RENDER_DIR/prometheus-config.yaml" 'CLUSTER_NAME'
kubectl apply -f "$RENDER_DIR/prometheus-config.yaml"
kubectl apply -f "$OBS_DIR/prometheus/alert-rules.yaml"

render_template "$OBS_DIR/prometheus/deployment.yaml" \
  "$RENDER_DIR/prometheus-deployment.yaml" 'PROM_RETENTION'
kubectl apply -f "$RENDER_DIR/prometheus-deployment.yaml"

# ---------------------------------------------------------------------------
# 3. Alertmanager. A blank ALERT_WEBHOOK_URL is not an error - it selects a null
#    receiver so alerts still collect in the UI.
# ---------------------------------------------------------------------------
log "Applying Alertmanager..."
if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
  ALERTMANAGER_ROUTE_RECEIVER="webhook"
  ALERTMANAGER_RECEIVERS=$(cat <<RECEIVERS
      - name: webhook
        webhook_configs:
          - url: ${ALERT_WEBHOOK_URL}
            send_resolved: true
RECEIVERS
)
  log "alerts route to the configured webhook"
else
  ALERTMANAGER_ROUTE_RECEIVER="null"
  ALERTMANAGER_RECEIVERS=$(cat <<'RECEIVERS'
      - name: "null"
RECEIVERS
)
  log "ALERT_WEBHOOK_URL is blank - alerts collect in Alertmanager only"
fi
export ALERTMANAGER_ROUTE_RECEIVER ALERTMANAGER_RECEIVERS

render_template "$OBS_DIR/alertmanager/deployment.yaml" \
  "$RENDER_DIR/alertmanager.yaml" 'ALERTMANAGER_ROUTE_RECEIVER ALERTMANAGER_RECEIVERS'
kubectl apply -f "$RENDER_DIR/alertmanager.yaml"

# ---------------------------------------------------------------------------
# 4. Loki + Promtail
# ---------------------------------------------------------------------------
log "Applying Loki..."
export LOKI_RETENTION
render_template "$OBS_DIR/loki/configmap.yaml" "$RENDER_DIR/loki-config.yaml" 'LOKI_RETENTION'
kubectl apply -f "$RENDER_DIR/loki-config.yaml"
kubectl apply -f "$OBS_DIR/loki/statefulset.yaml"

log "Applying Promtail (DaemonSet - covers every node, now and later)..."
kubectl apply -f "$OBS_DIR/promtail/daemonset.yaml"

# ---------------------------------------------------------------------------
# 5. Grafana. Root URL follows the domain when there is one, else the node IP,
#    always under /grafana so no domain is required.
# ---------------------------------------------------------------------------
log "Applying Grafana..."
HTTPS_PORT="$(svc_nodeport platform kong-proxy proxy-ssl 2>/dev/null || true)"
HOST="$(platform_host)"
if has_real_domain; then
  GRAFANA_ROOT_URL="https://${HOST}/grafana"
else
  GRAFANA_ROOT_URL="https://${HOST}:${HTTPS_PORT:-30443}/grafana"
fi
export GRAFANA_ROOT_URL

kubectl apply -f "$OBS_DIR/grafana/configmap.yaml"

# Dashboards ship as JSON files; fold them into a ConfigMap so adding one is
# just dropping a file in the directory.
kubectl -n observability create configmap grafana-dashboards \
  --from-file="$OBS_DIR/grafana/dashboards/" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

render_template "$OBS_DIR/grafana/deployment.yaml" \
  "$RENDER_DIR/grafana-deployment.yaml" 'GRAFANA_ROOT_URL'
kubectl apply -f "$RENDER_DIR/grafana-deployment.yaml"

# ---------------------------------------------------------------------------
# 6. Wait for everything.
# ---------------------------------------------------------------------------
log "Waiting for rollouts..."
kubectl -n observability rollout status deployment/prometheus   --timeout=180s
kubectl -n observability rollout status deployment/alertmanager --timeout=120s
kubectl -n observability rollout status statefulset/loki        --timeout=240s
kubectl -n observability rollout status daemonset/promtail      --timeout=180s
kubectl -n observability rollout status deployment/grafana      --timeout=180s
ok "all observability workloads Ready"

# ---------------------------------------------------------------------------
# 7. Route Grafana through Kong.
#
#    Kong is DB-less: the declarative ConfigMap is the whole config, so this
#    injects the grafana service into the live config rather than applying a
#    rival file. strip_path stays false because Grafana is configured to serve
#    from the /grafana sub-path itself.
# ---------------------------------------------------------------------------
log "Adding the Grafana route to Kong..."
# Indented to match kong.yaml AS STORED IN THE CONFIGMAP VALUE (services list
# items at 2 spaces), not the deeper indent the same YAML has inside the
# manifest file - kubectl strips the block-scalar indent when reading it back.
GRAFANA_ROUTE=$(cat <<'ROUTE'

  - name: grafana-service
    url: http://grafana.observability.svc:3000
    routes:
      - name: grafana-route
        paths:
          - /grafana
        strip_path: false
        protocols:
          - https
        https_redirect_status_code: 301
ROUTE
)

if kong_insert_block "grafana-service" "$GRAFANA_ROUTE"; then
  kubectl -n platform rollout restart deployment/kong
  kubectl -n platform rollout status deployment/kong --timeout=180s
  ok "Kong routes /grafana"
else
  log "Kong already routes /grafana - leaving the config alone"
fi

log ""
ok "Grafana: ${GRAFANA_ROOT_URL}  (user: ${GRAFANA_ADMIN_USER})"
log "Prometheus/Alertmanager/Loki are intentionally NOT exposed. Reach them with:"
log "  kubectl -n observability port-forward svc/prometheus 9090:9090"
