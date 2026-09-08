#!/usr/bin/env bash
# Deploy the NemoClaw workshop stack onto an existing OpenShift cluster.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_env

"$HERE/00-preflight.sh"

# Auto-detect the cluster's apps domain for Route hostnames.
DOMAIN="${CLUSTER_APPS_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')}"

# Deploy the OpenShift observability stack (operators + MinIO + Tempo + Loki + OTEL).
"$HERE/15-observability.sh"

# Create namespaces out-of-band (NOT via Helm — helm uninstall deletes namespaces).
for ns in openshell monitoring demo; do
  oc create namespace "$ns" --dry-run=client -o yaml | oc apply -f -
done

# Apply agent-sandbox CRD out-of-band (cluster-scoped, must not be Helm-managed).
ASB_VERSION="${AGENT_SANDBOX_VERSION:-v0.4.6}"
oc apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${ASB_VERSION}/manifest.yaml"

# Add Helm repos required by the monitoring subchart (standalone Grafana).
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# Build subchart dependencies first (helm dependency build is NOT recursive).
log "Building Helm chart dependencies"
helm dependency build "$REPO_ROOT/chart/charts/openshell/"
helm dependency build "$REPO_ROOT/chart/charts/monitoring/"
helm dependency build "$REPO_ROOT/chart/"

# Install openshell + workshop (release: nemoclaw, namespace: openshell).
log "Installing openshell + workshop"
helm upgrade --install nemoclaw "$REPO_ROOT/chart/" \
  -n openshell \
  -f "$REPO_ROOT/chart/values.yaml" \
  --set global.clusterAppsDomain="$DOMAIN" \
  --set monitoring.enabled=false \
  --set-string workshop.inference.apiKey="${NEMOCLAW_API_KEY:-}" \
  --set workshop.inference.baseUrl="${NEMOCLAW_INFERENCE_BASE_URL:-}" \
  --set workshop.inference.model="${NEMOCLAW_MODEL:-}" \
  --set openclaw.gatewayPassword="${OPENCLAW_GATEWAY_PASSWORD:-openclaw}" \
  --wait --timeout 15m

# Configure the gateway's inference provider (privacy router) so agents can reach a model.
API_KEY="${NEMOCLAW_PROVIDER_KEY:-${NEMOCLAW_API_KEY:-}}"
BASE_URL="${NEMOCLAW_INFERENCE_BASE_URL:-}"
MODEL="${NEMOCLAW_MODEL:-}"
PROVIDER="${NEMOCLAW_INFERENCE_PROVIDER:-default}"
if [[ -n "$BASE_URL" && -n "$MODEL" && -n "$API_KEY" ]]; then
  log "Configuring inference provider '${PROVIDER}' (via workshop pod)"
  oc -n openshell exec deploy/workshop -c workshop -- sh -c "
    openshell provider delete '$PROVIDER' 2>/dev/null || true
    openshell provider create --name '$PROVIDER' --type openai \
      --credential OPENAI_API_KEY=\"\$NEMOCLAW_API_KEY\" \
      --config OPENAI_BASE_URL=\"\$NEMOCLAW_INFERENCE_BASE_URL\" 2>&1 | grep -v UNDICI
    openshell inference set --provider '$PROVIDER' --model '$MODEL' 2>&1 | grep -v UNDICI
  " && log "Inference route set: provider=${PROVIDER} model=${MODEL}" \
    || warn "Inference provider setup failed — configure manually."
fi

# Install monitoring (Grafana + event-exporter) in its own namespace.
log "Installing monitoring (Grafana + event-exporter)"
helm upgrade --install nemoclaw-monitoring "$REPO_ROOT/chart/charts/monitoring/" \
  -n monitoring \
  --set global.clusterAppsDomain="$DOMAIN" \
  --set grafana.adminPassword="${MONITORING_GRAFANA_PASSWORD:-openclaw}" \
  --wait --timeout 10m

# Deploy the demo app via Kustomize (NOT Helm-managed — incident route does apply/delete).
if [[ "${DEPLOY_DEMO_APP:-true}" == "true" ]]; then
  oc apply -k "$REPO_ROOT/manifests/demo-app/"
fi

# Bring up the SRE agent fleet (runs inside the workshop pod where the openshell CLI,
# fleet.sh, fleet.txt, and all fleet-role manifests are already present).
log "Bringing up the agent fleet (via workshop pod)"
oc -n openshell exec deploy/workshop -c workshop -- \
  bash /app/scripts/fleet.sh up /app/fleet.txt \
  && log "Agent fleet is up" \
  || warn "Fleet setup failed — run './scripts/fleet.sh up fleet.txt' manually from the workshop pod."

[[ "${PROVISION_AGENT:-false}" == "true" ]] && "$HERE/45-openclaw.sh"

log "Workshop:  https://workshop-openshell.${DOMAIN}/"
log "Grafana:   https://grafana-monitoring.${DOMAIN}/grafana"
log "Console:   https://console-openshift-console.${DOMAIN}/"
