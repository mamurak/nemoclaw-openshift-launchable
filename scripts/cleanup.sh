#!/usr/bin/env bash
# Tear down the NemoClaw workshop stack — Helm releases, demo app, observability
# charts, orphaned cluster-scoped RBAC, and namespaces. Does NOT remove the
# agent-sandbox CRD or observability operators (those are shared cluster resources).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

log "Step 1/4: Removing Helm releases (openshell, workshop, monitoring)"
helm uninstall nemoclaw -n openshell 2>/dev/null && log "  nemoclaw uninstalled" || warn "  nemoclaw release not found (already removed?)"
helm uninstall nemoclaw-monitoring -n monitoring 2>/dev/null && log "  nemoclaw-monitoring uninstalled" || warn "  nemoclaw-monitoring release not found (already removed?)"

log "Step 2/4: Removing the demo app"
oc delete -k "$HERE/../manifests/demo-app/" --ignore-not-found 2>/dev/null && log "  demo app removed" || warn "  demo app not found"

log "Step 3/4: Removing observability Helm releases (OTEL, Tempo, Loki, MinIO)"
for rel_ns in otel:observability-hub tempo:observability-hub loki:openshift-logging minio:observability-hub; do
  rel="${rel_ns%%:*}"; ns="${rel_ns##*:}"
  helm uninstall "$rel" -n "$ns" 2>/dev/null && log "  $rel uninstalled from $ns" || warn "  $rel release not found in $ns"
done

log "  Cleaning cluster-scoped RBAC by Helm release label"
oc delete clusterrolebinding -l app.kubernetes.io/managed-by=Helm,meta.helm.sh/release-name=nemoclaw --ignore-not-found 2>/dev/null || true
oc delete clusterrolebinding -l app.kubernetes.io/managed-by=Helm,meta.helm.sh/release-name=nemoclaw-monitoring --ignore-not-found 2>/dev/null || true

log "Step 4/4: Removing namespaces"
for ns in openshell monitoring demo observability-hub; do
  oc delete namespace "$ns" --ignore-not-found 2>/dev/null && log "  $ns deleted" || warn "  $ns not found"
done

warn "openshift-monitoring and openshift-logging are shared platform namespaces — not removed."
warn "Agent-sandbox CRD and observability operators are not removed. See README for manual steps."
log "Cleanup complete."
