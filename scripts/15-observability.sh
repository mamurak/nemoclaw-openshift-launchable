#!/usr/bin/env bash
# Phase 15 — deploy the OpenShift observability stack.
# Installs operators (Loki, Tempo, CLO, OTEL, COO), enables User Workload Monitoring,
# and deploys MinIO + TempoStack + LokiStack + ClusterLogForwarder + OTEL Collector.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_env

log "Phase 15 — OpenShift observability stack"

# --- required CLI tools for operator management ---
require_cmd envsubst
require_cmd yq
require_cmd jq

# --- install operators (idempotent — skips if already installed) ---
log "Installing observability operators"
declare -A OPERATOR_NS=(
  [observability]=openshift-cluster-observability-operator
  [otel]=openshift-opentelemetry-operator
  [tempo]=openshift-tempo-operator
  [logging]=openshift-logging
  [loki]=openshift-operators-redhat
)
for op in observability otel tempo logging loki; do
  log "  ▶ $op → ${OPERATOR_NS[$op]}"
  "$HERE/lib/operator-manager.sh" -i "$op" -n "${OPERATOR_NS[$op]}"
done

# --- enable User Workload Monitoring ---
log "Enabling User Workload Monitoring"
"$HERE/lib/enable-uwm.sh"

# --- create namespace for Tempo / OTEL / MinIO ---
oc create namespace observability-hub --dry-run=client -o yaml | oc apply -f -

# --- deploy MinIO (object storage for Loki + Tempo) ---
log "Deploying MinIO"
helm upgrade --install minio "$REPO_ROOT/deploy/observability/minio/" \
  -n observability-hub \
  --wait --timeout 5m

# --- deploy TempoStack ---
log "Deploying TempoStack"
helm upgrade --install tempo "$REPO_ROOT/deploy/observability/tempo/" \
  -n observability-hub \
  --wait --timeout 10m

# --- deploy LokiStack + ClusterLogForwarder ---
log "Deploying LokiStack + ClusterLogForwarder"
helm upgrade --install loki "$REPO_ROOT/deploy/observability/loki/" \
  -n openshift-logging \
  --wait --timeout 10m

# --- deploy OTEL Collector ---
log "Deploying OTEL Collector"
helm upgrade --install otel "$REPO_ROOT/deploy/observability/otel-collector/" \
  -n observability-hub \
  --wait --timeout 5m

log "Phase 15 complete — observability stack deployed."
