#!/usr/bin/env bash
# Top-level orchestrator — deploys the NemoClaw workshop stack onto an existing
# OpenShift cluster. Runs preflight, then the deploy script, then optional extras.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_env

log "NemoClaw-on-OpenShift: starting deployment"

# Core deployment (preflight, Helm chart, namespaces, CRDs, demo app).
"$HERE/deploy.sh"

# Interactive workshop website (Next.js + live shell). Set DEPLOY_WORKSHOP=false to skip.
if [[ "${DEPLOY_WORKSHOP:-true}" == "true" ]]; then
  "$HERE/70-workshop.sh" || warn "phase 70 (workshop site) failed — non-fatal; the stack is still up."
fi

# Full observability stack (Prometheus + Grafana + Loki + Tempo) — PRE-DEPLOYED as part
# of the platform so the fleet dashboards are ready out of the box. Set
# DEPLOY_MONITORING=false in .env to skip it on a very small instance.
if [[ "${DEPLOY_MONITORING:-true}" != "false" ]]; then
  "$HERE/80-monitoring.sh" || warn "phase 80 (monitoring) failed — non-fatal; the core stack is still up."
fi

# Auto-detect the cluster's apps domain for final summary.
DOMAIN="${CLUSTER_APPS_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo '<cluster-apps-domain>')}"

log "Done. Platform is up — now build your agent in the workshop:"
log "  Workshop:  https://workshop-openshell.${DOMAIN}/"
log "  Grafana:   https://grafana-monitoring.${DOMAIN}/grafana"
log "  Console:   https://console-openshift-console.${DOMAIN}/"
log "  -> Create your OpenClaw agent hands-on in the workshop (it is NOT pre-provisioned)."
log "     Once created, its UI password is: ${OPENCLAW_GATEWAY_PASSWORD:-openclaw}"
