#!/usr/bin/env bash
# fleet.sh — Part VI capstone: bring up the SRE copilot fleet from a simple spec, so you
# never repeat the per-agent setup by hand. Each line of the spec is:
#
#     name : backend            # backend = host:port the agent may reach, or "-" for none
#
# e.g.   logs    : loki.monitoring.svc.cluster.local:3100
#        metrics : kps-prometheus.monitoring.svc.cluster.local:9090
#        traces  : tempo.monitoring.svc.cluster.local:3200
#        writer  : -
#
# For each agent this: creates a sealed sandbox whose deny-by-default policy allows ONLY
# that one telemetry backend (the egress is specific to the agent's tool), and stages the
# agent's IDENTITY.md / SOUL.md from manifests/openclaw/fleet-roles/<name>/ — so each agent
# has its own role and persona. Usage: ./scripts/fleet.sh up <spec> | status | down [<spec>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
[[ -f "$REPO/.env" ]] && set -a && . "$REPO/.env" && set +a || true
# Auto-discover the gateway Route URL and register it before fleet operations.
GW_URL="${OPENSHELL_CLI_ENDPOINT:-$(oc -n openshell get route openshell-gateway -o jsonpath='https://{.spec.host}' 2>/dev/null || echo http://openshell.openshell.svc.cluster.local:8080)}"
if command -v openshell >/dev/null 2>&1; then
  openshell gateway add "$GW_URL" --local --name cluster >/dev/null 2>&1 || true
  openshell gateway select cluster >/dev/null 2>&1 || true
fi

IMAGE="${OPENCLAW_SANDBOX_IMAGE:-ghcr.io/ansjindal/openclaw-sandbox:2026.6.10}"
MODEL="${NEMOCLAW_MODEL:-}"; PROVIDER="${NEMOCLAW_INFERENCE_PROVIDER:-default}"
API="${NEMOCLAW_INFERENCE_API:-openai-completions}"
ROLES="$REPO/manifests/openclaw/fleet-roles"
SKILLDIR="$REPO/manifests/openclaw/skills/cluster-telemetry"   # the in-cluster telemetry skill
ox() { openshell sandbox exec -n "$1" -- sh -c "$2" </dev/null 2>&1 | grep -viE 'UNDICI|trace-warn' || true; }
b64() { base64 | tr -d '\n'; }

policy_for() {                       # $1 = backend host:port (or "-")
  local be="$1" host="${1%%:*}" port="${1##*:}" extra=""
  [[ "$be" != "-" && -n "$be" ]] && extra="
  tool-egress:
    name: tool-egress
    endpoints: [ { host: ${host}, port: ${port}, access: full } ]
    binaries: [ {path: /usr/bin/node}, {path: /usr/local/bin/node}, {path: /usr/bin/curl} ]"
  cat <<YAML
version: 1
filesystem_policy: { include_workdir: true, read_only: [/usr,/lib,/proc,/dev/urandom,/app,/etc,/var/log], read_write: [/sandbox,/tmp,/dev/null] }
landlock: { compatibility: best_effort }
process: { run_as_user: sandbox, run_as_group: sandbox }
network_policies:
  in-cluster-registry:
    name: in-cluster-registry
    endpoints: [ { host: registry.openshell.svc.cluster.local, port: 4873, access: full, protocol: rest, allow_encoded_slash: true } ]
    binaries: [ {path: /usr/bin/npm}, {path: /usr/local/bin/npm}, {path: /usr/bin/node}, {path: /usr/local/bin/node} ]${extra}
YAML
}

up() {
  local spec="${1:?usage: fleet.sh up <spec>}"
  local REG="registry.openshell.svc.cluster.local:4873"
  # Whitespace-separated columns:  name   backend(host:port|-)   skill(@scope/name|-)
  # (NOT colon-separated — backend hosts contain a colon, e.g. loki…:3100.)
  local -a NM BK SK POL
  # Read the spec on FD 3 (the openshell commands below read stdin and would otherwise
  # eat the rest of the file). Collect the fleet, then create CONCURRENTLY so the agents
  # bootstrap in parallel (~1 min total) instead of one-after-another (~1 min each).
  while read -r name backend skill <&3; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    NM+=("$name"); BK+=("${backend:--}"); SK+=("${skill:--}")
  done 3< "$spec"
  echo "Bringing up ${#NM[@]} agents from ${IMAGE} — in parallel:"

  local i name
  for i in "${!NM[@]}"; do
    name="${NM[$i]}"
    # Prefer a committed per-role policy file (fleet-roles/<name>/policy.yaml, the OpenShell
    # way); fall back to a generated one derived from the backend column when absent.
    if [[ -f "$ROLES/$name/policy.yaml" ]]; then
      POL[$i]="$ROLES/$name/policy.yaml"
    else
      POL[$i]="/tmp/fleet-${name}.policy.yaml"
      policy_for "${BK[$i]}" > "${POL[$i]}"
    fi
    echo "▶ ${name}  (egress=${BK[$i]}  skill=${SK[$i]}  policy=${POL[$i]})"
    openshell sandbox delete "$name" </dev/null >/dev/null 2>&1 || true
  done
  sleep 2
  for i in "${!NM[@]}"; do
    name="${NM[$i]}"
    openshell sandbox create --name "$name" --policy "${POL[$i]}" --from "$IMAGE" --no-tty -- true </dev/null >"/tmp/fleet-${name}.log" 2>&1 &
  done
  echo "   …creating; waiting for each to reach Ready (they bootstrap concurrently)…"

  for i in "${!NM[@]}"; do
    name="${NM[$i]}"
    local ready=false j
    for j in $(seq 1 72); do
      openshell sandbox exec -n "$name" -- true </dev/null >/dev/null 2>&1 && { ready=true; break; }
      sleep 5
    done
    if [[ "$ready" != true ]]; then
      echo "   ✗ ${name} not ready — create log:"; tail -6 "/tmp/fleet-${name}.log" 2>/dev/null | grep -viE 'UNDICI|trace-warn' | sed 's/^/       /'
      continue
    fi
    # stage the agent's persona (IDENTITY.md / SOUL.md) from fleet-roles/<name> — the role
    if [[ -d "$ROLES/$name" ]]; then
      for f in IDENTITY.md SOUL.md BOOTSTRAP.md; do
        [[ -f "$ROLES/$name/$f" ]] && ox "$name" "mkdir -p /sandbox && echo $(b64 < "$ROLES/$name/$f") | base64 -d > /sandbox/$f"
      done
    fi
    # stage the cluster-telemetry skill for any agent with a backend — this is how a sealed
    # specialist reads its in-cluster Loki/Prometheus/Tempo (web_fetch blocks internal hosts;
    # the skill shells out to curl, still bounded by the agent's single-backend egress policy).
    if [[ "${BK[$i]}" != "-" && -n "${BK[$i]}" && -d "$SKILLDIR" ]]; then
      ox "$name" "mkdir -p /sandbox/.agents/skills/cluster-telemetry"
      for f in SKILL.md tq.js; do
        [[ -f "$SKILLDIR/$f" ]] && ox "$name" "echo $(b64 < "$SKILLDIR/$f") | base64 -d > /sandbox/.agents/skills/cluster-telemetry/$f"
      done
    fi
    if [[ -n "$MODEL" ]]; then
      # Valid OpenClaw config schema (matches a working agent): the model is a provider-scoped
      # id, and the provider points at inference.local (the supervisor injects the real key).
      local cfg; cfg=$(printf '{"agents":{"defaults":{"model":{"primary":"custom/%s"}}},"models":{"providers":{"custom":{"baseUrl":"https://inference.local/v1","apiKey":"openshell-router","api":"%s","models":[{"id":"%s","name":"%s"}]}}}}' "$MODEL" "$API" "$MODEL" "$MODEL")
      ox "$name" "mkdir -p /sandbox/.openclaw && echo $(printf '%s' "$cfg" | b64) | base64 -d > /sandbox/.openclaw/openclaw.json"
    fi
    # optional registry skill (best-effort — the agent still works via its SOUL if absent)
    if [[ "${SK[$i]}" != "-" && -n "${SK[$i]}" ]]; then
      local auth; auth=$(printf 'workshop:%s' "${OPENCLAW_REGISTRY_PASSWORD:-wad26-skills}" | b64)
      ox "$name" "printf 'registry=http://${REG}/\n@workshop:registry=http://${REG}/\n//${REG}/:_auth=${auth}\n' > /sandbox/.npmrc"
      ox "$name" "NODE_NO_WARNINGS=1 openclaw plugins install '${SK[$i]}' 2>&1 | tail -1 | sed 's/^/     /'" || true
    fi
    echo "   ✓ ${name} ready + configured"
  done
  echo "Done. Run './scripts/fleet.sh status' (or open the Fleet page in the workshop)."
}

status() { openshell sandbox list 2>/dev/null | grep -viE 'UNDICI|trace-warn'; }
down()   { local s="${1:-}"; if [[ -n "$s" ]]; then awk '!/^#/ && NF{print $1}' "$s"; else openshell sandbox list 2>/dev/null | awk 'NR>1{print $1}'; fi | while read -r n; do [[ -n "$n" ]] && openshell sandbox delete "$n" >/dev/null 2>&1 && echo "removed $n"; done; }

case "${1:-}" in
  up) shift; up "$@" ;;
  status) status ;;
  down) shift; down "$@" ;;
  *) echo "usage: fleet.sh up <spec> | status | down [<spec>]"; exit 1 ;;
esac
