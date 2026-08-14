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

# Build and install the umbrella chart.
helm dependency build "$REPO_ROOT/chart/"
helm upgrade --install nemoclaw "$REPO_ROOT/chart/" \
  -n openshell \
  -f "$REPO_ROOT/chart/values.yaml" \
  --set global.clusterAppsDomain="$DOMAIN" \
  --set-string workshop.inference.apiKey="${NEMOCLAW_API_KEY:-}" \
  --set workshop.inference.baseUrl="${NEMOCLAW_INFERENCE_BASE_URL:-}" \
  --set workshop.inference.model="${NEMOCLAW_MODEL:-}" \
  --set openclaw.gatewayPassword="${OPENCLAW_GATEWAY_PASSWORD:-openclaw}" \
  --wait --timeout 15m

# Deploy the demo app via Kustomize (NOT Helm-managed — incident route does apply/delete).
if [[ "${DEPLOY_DEMO_APP:-true}" == "true" ]]; then
  oc apply -k "$REPO_ROOT/manifests/demo-app/"
fi

[[ "${PROVISION_AGENT:-false}" == "true" ]] && "$HERE/45-openclaw.sh"

log "Workshop:  https://workshop-openshell.${DOMAIN}/"
log "Grafana:   https://grafana-monitoring.${DOMAIN}/grafana"
log "Console:   https://console-openshift-console.${DOMAIN}/"
