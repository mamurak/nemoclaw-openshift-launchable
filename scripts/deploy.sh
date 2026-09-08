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

# Create namespaces out-of-band (NOT via Helm — helm uninstall deletes namespaces).
for ns in openshell monitoring demo; do
  oc create namespace "$ns" --dry-run=client -o yaml | oc apply -f -
done

# Apply agent-sandbox CRD out-of-band (cluster-scoped, must not be Helm-managed).
ASB_VERSION="${AGENT_SANDBOX_VERSION:-v0.4.6}"
oc apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${ASB_VERSION}/manifest.yaml"

# Add Helm repos required by the monitoring subchart.
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
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
# Runs unconditionally when creds are present — independent of PROVISION_AGENT / 45-openclaw.sh.
API_KEY="${NEMOCLAW_PROVIDER_KEY:-${NEMOCLAW_API_KEY:-}}"
BASE_URL="${NEMOCLAW_INFERENCE_BASE_URL:-}"
MODEL="${NEMOCLAW_MODEL:-}"
PROVIDER="${NEMOCLAW_INFERENCE_PROVIDER:-default}"
if [[ -n "$BASE_URL" && -n "$MODEL" && -n "$API_KEY" ]]; then
  if ! command -v openshell >/dev/null 2>&1; then
    log "Installing the openshell CLI"
    curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh >/dev/null 2>&1 \
      || warn "openshell CLI install failed — inference provider not configured."
  fi
  export PATH="$PATH:$HOME/.local/bin"
  GW_URL="${OPENSHELL_CLI_ENDPOINT:-$(oc -n openshell get route openshell-gateway -o jsonpath='https://{.spec.host}' 2>/dev/null || echo http://openshell.openshell.svc.cluster.local:8080)}"
  openshell gateway add "$GW_URL" --local --name cluster >/dev/null 2>&1 || true
  openshell gateway select cluster >/dev/null 2>&1 || true
  log "Configuring inference provider '${PROVIDER}'"
  openshell provider delete "$PROVIDER" >/dev/null 2>&1 || true
  if openshell provider create --name "$PROVIDER" --type openai \
       --credential OPENAI_API_KEY="$API_KEY" --config OPENAI_BASE_URL="$BASE_URL" >/dev/null 2>&1; then
    openshell inference set --provider "$PROVIDER" --model "$MODEL" >/dev/null 2>&1 \
      && log "Inference route set: provider=${PROVIDER} model=${MODEL}" \
      || warn "openshell inference set failed"
  else
    warn "openshell provider create failed — configure inference manually."
  fi
fi

# Install monitoring in its own namespace (separate release so {{ .Release.Namespace }} = monitoring).
log "Installing monitoring stack"
helm upgrade --install nemoclaw-monitoring "$REPO_ROOT/chart/charts/monitoring/" \
  -n monitoring \
  --set global.clusterAppsDomain="$DOMAIN" \
  --set kps.grafana.adminPassword="${MONITORING_GRAFANA_PASSWORD:-openclaw}" \
  --wait --timeout 15m

# Deploy the demo app via Kustomize (NOT Helm-managed — incident route does apply/delete).
if [[ "${DEPLOY_DEMO_APP:-true}" == "true" ]]; then
  oc apply -k "$REPO_ROOT/manifests/demo-app/"
fi

[[ "${PROVISION_AGENT:-false}" == "true" ]] && "$HERE/45-openclaw.sh"

log "Workshop:  https://workshop-openshell.${DOMAIN}/"
log "Grafana:   https://grafana-monitoring.${DOMAIN}/grafana"
log "Console:   https://console-openshift-console.${DOMAIN}/"
