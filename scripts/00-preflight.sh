#!/usr/bin/env bash
# Phase 00 — preflight. Validates that the user is logged into an OpenShift cluster
# and has the required CLI tools. No GPU needed — inference is remote.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_env

log "Preflight checks"

# --- required CLI tools ---
require_cmd oc
require_cmd helm

# --- OpenShift login ---
if oc whoami >/dev/null 2>&1; then
  log "Logged in to OpenShift as $(oc whoami) on $(oc whoami --show-server 2>/dev/null || echo '(unknown server)')"
else
  die "Not logged in to OpenShift — run 'oc login' first."
fi

# --- oc / helm versions (informational) ---
OC_VER="$(oc version --client 2>/dev/null | head -1 || echo unknown)"
HELM_VER="$(helm version --short 2>/dev/null || echo unknown)"
log "oc: ${OC_VER}  |  helm: ${HELM_VER}"

# --- remote inference endpoint (OPTIONAL) ---
# Hybrid model config: if these are set the agent is pre-configured; if not, it deploys
# UNCONFIGURED and the user adds a provider/model/key in the OpenClaw UI. So warn, never fail —
# preflight must not halt the whole provision just because creds weren't supplied.
[[ -n "${NEMOCLAW_INFERENCE_PROVIDER:-}" ]] || warn "NEMOCLAW_INFERENCE_PROVIDER unset — agent will deploy unconfigured (set the model in the OpenClaw UI)."
[[ -n "${NEMOCLAW_INFERENCE_BASE_URL:-}" ]] || warn "NEMOCLAW_INFERENCE_BASE_URL empty — agent will deploy unconfigured."
[[ -n "${NEMOCLAW_API_KEY:-}" ]]            || warn "NEMOCLAW_API_KEY empty — agent will deploy unconfigured."

log "Preflight complete."
