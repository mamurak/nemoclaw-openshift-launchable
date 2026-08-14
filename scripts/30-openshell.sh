#!/usr/bin/env bash
# Phase 30 — deploy the OpenShell gateway onto OpenShift via the official OCI Helm
# chart, configured with the KUBERNETES compute driver so sandbox pods run as native
# OpenShift pods. SCCs apply. Chart: oci://ghcr.io/nvidia/openshell/helm-chart (alpha).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_env

require_cmd oc
require_cmd helm

NS="${OPENSHELL_NAMESPACE:-openshell}"
CHART="${OPENSHELL_CHART:-oci://ghcr.io/nvidia/openshell/helm-chart}"

log "Creating namespace ${NS}"
oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -

# OpenShell's Kubernetes compute driver watches the agent-sandbox CRD
# (sandboxes.agents.x-k8s.io). Without it the gateway logs a 404 watch loop and can't
# create sandboxes. Install the CRD + controller before the gateway starts.
#
# PIN v0.4.6 — DO NOT track "latest". The OpenShell gateway (0.0.70) speaks the
# agent-sandbox v1alpha1 API: it annotates sandboxes with
# `api.agents.x-k8s.io/v1alpha1-sandbox-state` and, in IssueSandboxToken, verifies a
# sandbox pod is owned by a *v1alpha1* Sandbox. agent-sandbox v0.5.0+ switched the
# storage version to v1beta1, so its controller stamps pod ownerReferences as
# `agents.x-k8s.io/v1beta1`. The gateway then rejects every supervisor bootstrap with
# `PERMISSION_DENIED: pod is not controlled by an OpenShell Sandbox`, the supervisor
# crash-loops, and gateway-driven sandboxes never reach Ready. v0.4.6 is the last
# release that is v1alpha1-only (v0.5.0 introduced v1beta1). Revisit when the gateway
# adopts v1beta1.
ASB_VERSION="${AGENT_SANDBOX_VERSION:-v0.4.6}"
if ! oc get crd sandboxes.agents.x-k8s.io >/dev/null 2>&1; then
  log "Installing agent-sandbox CRD + controller (${ASB_VERSION})"
  oc apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${ASB_VERSION}/manifest.yaml"
fi

# SCC grants (BEFORE install — bindings may reference SAs that don't exist yet).
# Official OpenShift posture grants `privileged` to the sandbox SA. But the chart's
# pre-install certgen HOOK and the gateway run under the `openshell`/`default` SAs — on
# MicroShift those also need an SCC or the certgen Job never schedules and helm fails with
# "job openshell-certgen failed: DeadlineExceeded". So grant all three.
log "Granting SCCs (privileged: openshell-sandbox; anyuid: gateway + certgen-hook SAs)"
oc -n "$NS" adm policy add-scc-to-user privileged -z openshell-sandbox 2>/dev/null || \
  warn "Could not add privileged SCC to openshell-sandbox."
for sa in openshell default; do
  oc -n "$NS" adm policy add-scc-to-user anyuid -z "$sa" 2>/dev/null || \
    warn "Could not add anyuid SCC to '$sa'."
done

# PIN the chart version — DO NOT track "latest". The whole stack is validated against a
# specific gateway/supervisor build: 0.0.71 (helm-chart-0.0.71, app 0.0.71) provisions
# clean and brings up healthy sandboxes (verified end-to-end 2026-06-28). Tracking latest
# risks pulling a gateway that's incompatible with the pinned agent-sandbox v0.4.6 above,
# or a supervisor build that regresses session bootstrap. Override with OPENSHELL_VERSION
# to test a newer chart, then re-validate before bumping this default.
OPENSHELL_VERSION="${OPENSHELL_VERSION:-0.0.71}"
VERSION_ARG=(--version "$OPENSHELL_VERSION")
log "Pinning OpenShell chart version ${OPENSHELL_VERSION}"

log "helm upgrade --install openshell (in-cluster gateway = Kubernetes compute driver)"
# upgrade --install is idempotent — a re-run reuses the existing release instead of failing
# with "cannot re-use a name that is still in use".
helm upgrade --install openshell "$CHART" "${VERSION_ARG[@]}" \
  -n "$NS" \
  -f "$REPO_ROOT/helm/openshell-values.yaml" \
  --wait --timeout 10m

# The gateway renders most settings (incl. auth) into a ConfigMap (gateway.toml), so a
# values change on a re-run won't restart the pod by itself. Force a restart so config
# changes actually take effect, then wait for the new pod.
log "Restarting the gateway to pick up config (gateway.toml) changes"
oc -n "$NS" rollout restart statefulset/openshell 2>/dev/null || true
log "Waiting for the gateway StatefulSet to become ready"
oc -n "$NS" rollout status statefulset/openshell --timeout=300s || oc -n "$NS" get pods

# Expose the gateway. Single node = NodePort (the Service pins 30808; phase 50's socat
# forwarder publishes it on the host so the `openshell` CLI reaches 127.0.0.1:30808).
# Also publish an OpenShift Route as a DNS-capable alternative.
log "Exposing the gateway (NodePort 30808 + an OpenShift Route)"
oc apply -f "$REPO_ROOT/manifests/openshell-route.yaml" 2>/dev/null || true
ROUTE_HOST="$(oc -n "$NS" get route openshell-gateway -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "$ROUTE_HOST" ]] && log "Gateway Route: https://${ROUTE_HOST}"

log "OpenShell gateway deployed:"
oc -n "$NS" get pods,svc,route
# Sanity: the compute driver should be listing sandboxes (not 404-looping on the CRD).
if oc -n "$NS" logs openshell-0 --tail=20 2>/dev/null | grep -q "Listing sandboxes from Kubernetes"; then
  log "Kubernetes compute driver healthy (watching sandboxes.agents.x-k8s.io)."
else
  warn "Gateway up but compute-driver watch not confirmed — check 'oc -n $NS logs openshell-0'."
fi

# Pre-pull the sandbox runtime image onto the node. It's multi-GB, so the FIRST
# `openshell sandbox create` would otherwise block for minutes while the workspace-init
# + agent containers pull it — a terrible first impression in a live workshop. A
# fire-and-forget Job makes the kubelet pull it now (kubelet pulls the image before
# running the container, so the pull happens even though the container just exits).
# We don't wait on it: provisioning continues while the layers download in the
# background, and by the time an attendee creates a sandbox it's cached locally.
SANDBOX_IMG="$(awk -F': *' '/^[[:space:]]*sandboxImage:/{print $2; exit}' "$REPO_ROOT/helm/openshell-values.yaml" | tr -d '"')"
if [[ -n "$SANDBOX_IMG" ]]; then
  log "Pre-pulling sandbox image onto the node (background, one-time): $SANDBOX_IMG"
  oc -n "$NS" apply -f - >/dev/null <<YAML || warn "Could not create sandbox-image pre-pull Job (first sandbox will pull on demand)."
apiVersion: batch/v1
kind: Job
metadata:
  name: sandbox-image-prepull
  namespace: ${NS}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600
  template:
    spec:
      serviceAccountName: openshell-sandbox
      restartPolicy: Never
      containers:
      - name: prepull
        image: ${SANDBOX_IMG}
        imagePullPolicy: IfNotPresent
        command: ["sh", "-c", "exit 0"]
YAML
fi

# --- private skill registry (Verdaccio) — cluster-level, deployed once ---
# The agents' single governed skill+dep source: the sandbox egress policy
# (policies/openclaw-sandbox.yaml) allows ONLY this Service, and Verdaccio uplinks npmjs +
# caches transitive deps so sealed agents never reach the public internet directly. It's a
# shared cluster workload (one Deployment+Service+PVC for every agent and the skills lesson),
# so it lives here in the cluster phase — not in per-agent provisioning (phase 45).
REGISTRY_MANIFEST="$REPO_ROOT/manifests/openclaw/registry.yaml"
if [[ -f "$REGISTRY_MANIFEST" ]]; then
  log "Deploying the private skill registry (Verdaccio) from $REGISTRY_MANIFEST"
  oc apply -f "$REGISTRY_MANIFEST" >/tmp/registry-apply.log 2>&1 \
    || warn "registry apply failed — see /tmp/registry-apply.log"
  oc -n "$NS" rollout status deploy/registry --timeout=150s >/dev/null 2>&1 \
    && log "Skill registry Ready at registry.${NS}.svc.cluster.local:4873" \
    || warn "registry not Ready yet — skill installs from it may fail until it settles."
else
  warn "No registry manifest at $REGISTRY_MANIFEST — agents will have no in-cluster skill source."
fi
