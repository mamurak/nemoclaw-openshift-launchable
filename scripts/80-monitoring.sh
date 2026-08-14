#!/usr/bin/env bash
# Phase 80 — full observability stack: kube-prometheus-stack (Prometheus +
# Alertmanager + Grafana + node-exporter + kube-state-metrics) + Loki (logs) + Tempo
# (traces), with a pre-loaded Agent Fleet dashboard. PRE-DEPLOYED with the platform; the
# gating lives in setup.sh (DEPLOY_MONITORING=false to skip). Running this script directly
# always deploys.
#
# Grafana login: admin / ${MONITORING_GRAFANA_PASSWORD:-openclaw}.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_env

require_cmd oc; require_cmd helm
NS=monitoring
GRAFANA_PW="${MONITORING_GRAFANA_PASSWORD:-openclaw}"

log "Adding helm repos (prometheus-community, grafana)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community grafana >/dev/null 2>&1 || true

oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -

# Grant SCCs up front to the namespace 'default' SA + (after install) every chart SA.
# node-exporter mounts host /proc,/sys,/ and a host port — it needs privileged on OpenShift.
grant_sccs() {
  for sa in $(oc -n "$NS" get sa -o name 2>/dev/null | sed 's#serviceaccount/##'); do
    oc -n "$NS" adm policy add-scc-to-user privileged -z "$sa" >/dev/null 2>&1 || true
  done
}
oc -n "$NS" adm policy add-scc-to-user privileged -z default >/dev/null 2>&1 || true

log "Installing kube-prometheus-stack (Prometheus + Grafana + exporters) — no --wait yet"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n "$NS" -f "$REPO_ROOT/helm/monitoring/kube-prometheus-stack.values.yaml" \
  --set grafana.adminPassword="$GRAFANA_PW" --timeout 10m || warn "kps install returned non-zero (continuing to grant SCCs)."

log "Granting privileged SCC to monitoring SAs (node-exporter needs it on OpenShift)"
grant_sccs
# nudge the node-exporter DaemonSet + others that may have failed pre-SCC
oc -n "$NS" rollout restart daemonset -l release=kps 2>/dev/null || true
oc -n "$NS" delete pod -l app.kubernetes.io/name=prometheus-node-exporter 2>/dev/null || true

log "Installing Loki (logs) + Tempo (traces)"
helm upgrade --install loki grafana/loki \
  -n "$NS" -f "$REPO_ROOT/helm/monitoring/loki.values.yaml" --timeout 8m || warn "loki install returned non-zero."
helm upgrade --install tempo grafana/tempo \
  -n "$NS" -f "$REPO_ROOT/helm/monitoring/tempo.values.yaml" --timeout 8m || warn "tempo install returned non-zero."
grant_sccs

log "Applying Grafana datasources (Loki + Tempo) + Agent Fleet dashboard"
oc apply -f "$REPO_ROOT/manifests/monitoring/grafana-extras.yaml"

log "Deploying kubernetes-event-exporter → Loki (feeds the fleet's 'events' agent)"
oc apply -f "$REPO_ROOT/manifests/monitoring/event-exporter.yaml"

log "Deploying Grafana Alloy log shipper → Loki (feeds the fleet's 'logs' agent)"
oc apply -f "$REPO_ROOT/manifests/monitoring/log-shipper.yaml"

log "Deploying the instrumented demo app (shop-app) + loadgen (live traces/metrics/logs)"
oc apply -k "$REPO_ROOT/manifests/demo-app/"

log "Waiting for Grafana + Prometheus to become ready"
oc -n "$NS" rollout status deploy/kps-grafana --timeout=300s 2>/dev/null || oc -n "$NS" get pods
oc -n "$NS" rollout status statefulset/prometheus-kps-kube-prometheus-prometheus --timeout=300s 2>/dev/null || true

log "Monitoring stack deployed:"
oc -n "$NS" get pods 2>&1 | tail -20
log "Grafana login: admin / ${GRAFANA_PW}"
