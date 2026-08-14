#!/usr/bin/env bash
# Phase 45 — create the OpenClaw agent the STANDARD OpenShell way: a GATEWAY-managed
# sandbox (`openshell sandbox create` against the in-cluster gateway), NOT a hand-applied
# Sandbox CR and NOT nemoclaw. The OpenShell supervisor seals the agent in its own network
# namespace and governs egress through its proxy (deny-by-default + our policy). We then
# start the OpenClaw gateway inside the sandbox and expose its Control UI to the host with
# `openshell forward` (a NodePort cannot reach a sealed sandbox — the UI port lives in the
# agent's private netns; only the supervisor bridges it).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_env

require_cmd oc

NS="${OPENSHELL_NAMESPACE:-openshell}"
AGENT="${OPENCLAW_AGENT_NAME:-shifty}"
UI_PORT="${OPENCLAW_UI_PORT:-30789}"
GW_PASSWORD="${OPENCLAW_GATEWAY_PASSWORD:-openshell-wad26}"
SANDBOX_IMAGE="${OPENCLAW_SANDBOX_IMAGE:-ghcr.io/ansjindal/openclaw-sandbox:2026.6.10}"
GW_URL="${OPENSHELL_CLI_ENDPOINT:-$(oc -n openshell get route openshell-gateway -o jsonpath='https://{.spec.host}' 2>/dev/null || echo http://openshell.openshell.svc.cluster.local:8080)}"

# Inference creds (optional — if missing, the agent deploys UNCONFIGURED and the user
# sets a provider/model hands-on later). Never halt.
#
# These configure the OpenShell PRIVACY ROUTER, not the agent directly: the real endpoint
# + key live in a gateway-side provider (`openshell provider create`), and the gateway is
# told which provider/model to route (`openshell inference set`). The agent then sends its
# thinking to https://inference.local — the supervisor intercepts it (before policy) and
# routes to the provider, injecting the real key. The agent never holds the key, and the
# real inference host needs no egress-policy entry.
API_KEY="${NEMOCLAW_PROVIDER_KEY:-${NEMOCLAW_API_KEY:-}}"
BASE_URL="${NEMOCLAW_INFERENCE_BASE_URL:-}"
MODEL="${NEMOCLAW_MODEL:-}"
INFERENCE_API="${NEMOCLAW_INFERENCE_API:-openai-completions}"
PROVIDER="${NEMOCLAW_INFERENCE_PROVIDER:-default}"
INFERENCE_LOCAL_URL="https://inference.local/v1"   # the agent always points here
CONFIGURED=false
[[ -n "$BASE_URL" && -n "$MODEL" && -n "$API_KEY" ]] && CONFIGURED=true

# --- the openshell CLI must be installed + pointed at the in-cluster gateway ---
if ! command -v openshell >/dev/null 2>&1; then
  log "Installing the openshell CLI"
  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh >/dev/null 2>&1 \
    || die "openshell CLI install failed — required to create the gateway sandbox."
fi
export PATH="$PATH:$HOME/.local/bin"
log "Registering + selecting the OpenShell gateway at ${GW_URL}"
openshell gateway add "$GW_URL" --local --name cluster >/dev/null 2>&1 || true
openshell gateway select cluster >/dev/null 2>&1 || true
openshell status >/dev/null 2>&1 || warn "Gateway not answering at ${GW_URL} — is phase 30/50 done?"

# --- private skill registry (Verdaccio) — deployed cluster-level in phase 30 ---
# It's a shared, once-per-cluster Deployment (not per-agent), so its deploy lives in phase 30.
# Here we only need its in-cluster address to point this sandbox's npm at it (below).
REGISTRY_HOST="registry.${NS}.svc.cluster.local:4873"

# --- configure the privacy router: gateway-side provider + inference route ---
# The real endpoint + key are held by the gateway, NOT the agent. `inference.local` then
# resolves through this provider. (Verified end-to-end on 0.0.71: this does NOT disturb
# running sandbox sessions.)
if [[ "$CONFIGURED" == true ]]; then
  log "Creating inference provider '${PROVIDER}' (endpoint + key held by the gateway)"
  openshell provider delete "$PROVIDER" >/dev/null 2>&1 || true
  if openshell provider create --name "$PROVIDER" --type openai \
       --credential OPENAI_API_KEY="$API_KEY" --config OPENAI_BASE_URL="$BASE_URL" >/tmp/provider.log 2>&1; then
    openshell inference set --provider "$PROVIDER" --model "$MODEL" >/tmp/inference-set.log 2>&1 \
      && log "Inference route set: provider=${PROVIDER} model=${MODEL} (agent reaches it at inference.local)" \
      || warn "openshell inference set failed — see /tmp/inference-set.log"
  else
    warn "openshell provider create failed — see /tmp/provider.log; agent will deploy unconfigured."
    CONFIGURED=false
  fi
fi

# --- egress policy (deny-by-default; inference.local is intercepted before policy) ---
POLICY_SRC="$REPO_ROOT/policies/openclaw-sandbox.yaml"
if [[ -f "$POLICY_SRC" ]]; then
  POLICY_ARG=(--policy "$POLICY_SRC")
  log "Using egress policy $POLICY_SRC (deny-by-default; inference via inference.local)"
else
  warn "No policy file — sandbox will use the gateway default policy."
  POLICY_ARG=()
fi

# --- create the agent as a gateway-managed sandbox ---
ox() { openshell sandbox exec -n "$AGENT" -- "$@"; }
log "Creating gateway sandbox '${AGENT}' from ${SANDBOX_IMAGE}"
openshell sandbox delete "$AGENT" >/dev/null 2>&1 || true
sleep 2
# `-- true` exits immediately so create returns fast; the supervisor keeps the pod alive.
openshell sandbox create --name "$AGENT" --no-tty "${POLICY_ARG[@]}" \
  --from "$SANDBOX_IMAGE" -- true >/tmp/openclaw-create.log 2>&1 &
log "Waiting for the sandbox supervisor to finish bootstrap (gateway phase Ready)"
# Poll the real readiness condition (a live `exec` round-trip) up to a generous, configurable
# deadline — NOT a short fixed count. A cold first boot (image pull + supervisor) can take
# several minutes and would otherwise blow past a 240s cap, silently skipping the steps below.
ready=false
READY_TIMEOUT="${OPENCLAW_READY_TIMEOUT:-900}"
deadline=$(( SECONDS + READY_TIMEOUT ))
while (( SECONDS < deadline )); do
  if openshell sandbox exec -n "$AGENT" -- true >/dev/null 2>&1; then
    ready=true; log "Sandbox exec-ready after ${SECONDS}s"; break
  fi
  sleep 5
done
[[ "$ready" == true ]] || { warn "Sandbox not ready within ${READY_TIMEOUT}s — create log:"; tail -8 /tmp/openclaw-create.log; }

# --- point the sandbox's npm at the private registry + provision a publish user ---
# Skills are npm packages, so this is plain npm config: the @workshop scope AND the default
# registry resolve to Verdaccio (transitive deps uplink through it too). Anonymous read,
# authenticated publish. The user is created via the registry's PUT API from INSIDE the
# sandbox (the host cannot reach a ClusterIP; the sandbox can). 201 = created, 409 = exists.
if [[ "$ready" == true ]]; then
  REG_USER="${OPENCLAW_REGISTRY_USER:-workshop}"
  REG_PASS="${OPENCLAW_REGISTRY_PASSWORD:-wad26-skills}"
  log "Provisioning registry user '${REG_USER}' + pointing sandbox npm at ${REGISTRY_HOST}"
  cat > /tmp/mkuser.js <<JS
const http=require("http");
const b=JSON.stringify({name:"${REG_USER}",password:"${REG_PASS}"});
const r=http.request("http://${REGISTRY_HOST}/-/user/org.couchdb.user:${REG_USER}",{method:"PUT",headers:{"content-type":"application/json","content-length":Buffer.byteLength(b)}},res=>{let d="";res.on("data",c=>d+=c);res.on("end",()=>console.log("registry user status",res.statusCode));});
r.on("error",e=>console.log("registry user ERR",e.message));r.write(b);r.end();
JS
  MKUSER_B64="$(base64 < /tmp/mkuser.js | tr -d '\n')"
  ox sh -c "echo $MKUSER_B64 | base64 -d > /sandbox/mkuser.js && node /sandbox/mkuser.js" 2>&1 \
    | grep -i 'registry user' || warn "registry user provisioning unclear (see above)"
  # /sandbox/.npmrc: default + @workshop scope -> registry, plus basic auth for publish.
  AUTH_B64="$(printf '%s:%s' "$REG_USER" "$REG_PASS" | base64 | tr -d '\n')"
  cat > /tmp/agent-npmrc <<NPMRC
registry=http://${REGISTRY_HOST}/
@workshop:registry=http://${REGISTRY_HOST}/
//${REGISTRY_HOST}/:_auth=${AUTH_B64}
NPMRC
  NPMRC_B64="$(base64 < /tmp/agent-npmrc | tr -d '\n')"
  ox sh -c "echo $NPMRC_B64 | base64 -d > /sandbox/.npmrc" 2>&1 || warn "could not seed /sandbox/.npmrc"
  log "Sandbox npm -> ${REGISTRY_HOST} (@workshop scope + publish auth seeded in /sandbox/.npmrc)"
fi

# --- build OpenClaw config (inference + gateway auth) and stage it into /sandbox ---
# HOME=/sandbox; config at ~/.openclaw/openclaw.json. The agent is Landlock-confined to
# /sandbox + /tmp, so stage via `openshell sandbox exec` (base64 — exec rejects newlines).
if [[ "$CONFIGURED" == true ]]; then
  log "Configuring OpenClaw model (custom/${MODEL} via the privacy router at inference.local)"
  # baseUrl points at inference.local, NOT the real endpoint; the key is a placeholder —
  # the gateway's provider injects the real key when it routes the call upstream.
  OPENCLAW_JSON="$(jq -n \
    --arg url "$INFERENCE_LOCAL_URL" --arg model "$MODEL" \
    --arg api "$INFERENCE_API" --arg pw "$GW_PASSWORD" --arg port "$UI_PORT" \
    '{
       gateway: { auth: { password: $pw },
                  remote: { url: ("ws://127.0.0.1:" + $port), password: $pw },
                  controlUi: { dangerouslyAllowHostHeaderOriginFallback: true },
                  http: { endpoints: { chatCompletions: { enabled: true } } } },
       plugins: { entries: { duckduckgo: { enabled: true } } },
       tools:   { web: { search: { provider: "duckduckgo" } } },
       agents:  { defaults: { model: { primary: ("custom/" + $model) } } },
       models:  { providers: { custom: {
         baseUrl: $url, apiKey: "openshell-router", api: $api,
         models: [ { id: $model, name: $model } ]
       } } }
     }')"
else
  warn "No inference creds in env — deploying OpenClaw UNCONFIGURED (add a model in the UI)."
  OPENCLAW_JSON="$(jq -n --arg pw "$GW_PASSWORD" \
    '{ gateway: { auth: { password: $pw }, remote: { password: $pw },
                  controlUi: { dangerouslyAllowHostHeaderOriginFallback: true } } }')"
fi
OCB64="$(printf '%s' "$OPENCLAW_JSON" | base64 -w0)"
ox sh -c "mkdir -p /sandbox/.openclaw && echo $OCB64 | base64 -d > /sandbox/.openclaw/openclaw.json" \
  || warn "Could not stage openclaw.json."
ox openclaw config validate >/dev/null 2>&1 && log "openclaw.json valid." || warn "openclaw config validate failed."

# --- seed the agent's identity (IDENTITY.md / SOUL.md / BOOTSTRAP.md) into the workspace ---
SEED_DIR="$REPO_ROOT/manifests/openclaw/workspace-seed"
if [[ -d "$SEED_DIR" ]]; then
  log "Seeding agent workspace identity files"
  for f in "$SEED_DIR"/*; do
    [[ -f "$f" ]] || continue
    b="$(base64 -w0 < "$f")"
    ox sh -c "mkdir -p /sandbox/.openclaw/workspace && echo $b | base64 -d > /sandbox/.openclaw/workspace/$(basename "$f")" || true
  done
fi

# --- start the OpenClaw gateway (Control UI + WebSocket) inside the sandbox ---
log "Starting the OpenClaw gateway on :${UI_PORT} (auth=password)"
# setsid: run in its own session so it survives the exec session ending (a plain
# background process gets reaped when `openshell sandbox exec` returns).
ox sh -c "cd /sandbox && setsid nohup openclaw gateway run --port ${UI_PORT} --bind lan --auth password --password '${GW_PASSWORD}' --allow-unconfigured >/sandbox/gateway.log 2>&1 < /dev/null & echo \$! > /sandbox/gateway.pid; sleep 7; tail -5 /sandbox/gateway.log" \
  || warn "Could not start the OpenClaw gateway."

# --- bootstrap an admin operator device --------------------------------------------
# With --auth password the first CLI/device pairs as role `operator` but with only the
# `operator.pairing` scope, which can REQUEST pairing yet cannot APPROVE another device's
# request. On a fresh gateway no device has admin, so the first browser pairing hits a
# "who approves the approver" deadlock. Fix: pair the local operator now, grant it the
# admin scopes directly in the gateway's device table (devices/paired.json), and restart
# so the gateway loads them. Afterwards the operator can approve device pairings — from
# the CLI, the OpenClaw Control UI, or the workshop's Live OpenShell approvals panel.
log "Bootstrapping an admin operator device (so device-pairing approvals work out of the box)"
ox sh -c "openclaw devices list --url ws://127.0.0.1:${UI_PORT} --password '${GW_PASSWORD}' >/dev/null 2>&1 || true"
sleep 2
BOOTSTRAP_JS='const fs=require("fs");const dir="/sandbox/.openclaw/devices";const p=dir+"/paired.json";if(!fs.existsSync(p)){console.log("no paired devices yet");process.exit(0);}const d=JSON.parse(fs.readFileSync(p,"utf8"));const want=["operator.pairing","operator.admin","operator.approvals","operator.read","operator.write"];for(const k in d){d[k].scopes=want;d[k].approvedScopes=want;if(d[k].tokens&&d[k].tokens.operator){d[k].tokens.operator.scopes=want;}}fs.writeFileSync(p,JSON.stringify(d));try{fs.writeFileSync(dir+"/pending.json","{}");}catch(e){}console.log("admin-bootstrapped "+Object.keys(d).length+" device(s)");'
BJB64="$(printf '%s' "$BOOTSTRAP_JS" | base64 -w0)"
ox sh -c "echo $BJB64 | base64 -d > /sandbox/bootstrap-admin.js && node /sandbox/bootstrap-admin.js" \
  || warn "Admin bootstrap step failed — device approvals may need a manual grant."
ox sh -c "cd /sandbox && [ -f gateway.pid ] && kill \"\$(cat gateway.pid)\" 2>/dev/null; sleep 2; setsid nohup openclaw gateway run --port ${UI_PORT} --bind lan --auth password --password '${GW_PASSWORD}' --allow-unconfigured >/sandbox/gateway.log 2>&1 < /dev/null & echo \$! > /sandbox/gateway.pid; sleep 6; grep -E 'listening on ws' /sandbox/gateway.log | tail -1" \
  || warn "Gateway restart after admin bootstrap failed."

log "OpenClaw agent '${AGENT}' is a gateway-managed sandbox in namespace ${NS}:"
oc -n "$NS" get pod "$AGENT" 2>/dev/null || openshell sandbox list 2>/dev/null | head
log "Control UI password: ${GW_PASSWORD}  (first browser still needs device pairing approval)"
