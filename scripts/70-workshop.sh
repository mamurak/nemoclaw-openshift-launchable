#!/usr/bin/env bash
# Phase 70 (OPTIONAL, default on) — build + serve the interactive workshop website on the
# instance. It's a Next.js app (web/) with a live in-browser shell (node-pty) bridged to a
# real bash with `oc` + an `openclaw` helper, so attendees run lessons against the live
# cluster. Exposed on PORT 3000. Set DEPLOY_WORKSHOP=false to skip.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
load_env

WEB_DIR="$REPO_ROOT/web"
PORT="${WORKSHOP_PORT:-3000}"
[[ -d "$WEB_DIR" ]] || { warn "web/ not found — skipping workshop site."; exit 0; }

# --- Node 20+ and node-pty build deps ---
need_node=1
if command -v node >/dev/null 2>&1; then
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  (( major >= 20 )) && need_node=0
fi
if (( need_node )); then
  log "Installing Node.js 20 (for the workshop server)"
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1 || warn "NodeSource setup failed."
  sudo apt-get install -y nodejs >/dev/null 2>&1 || die "Could not install Node.js."
fi
# node-pty is a native addon — needs a toolchain.
sudo apt-get install -y python3 make g++ >/dev/null 2>&1 || warn "build tools may be missing (node-pty build could fail)."

log "Installing workshop deps + building (this takes a few minutes)"
cd "$WEB_DIR"
npm ci >/dev/null 2>&1 || npm install
npm run build

# --- OpenShell CLI for the in-browser shell ---
# The "Create a sandbox" lesson drives the gateway with `openshell sandbox create`. Install
# the CLI system-wide and register the in-cluster gateway against the stable host NodePort
# (published by phase 50), so the commands work from the lab shell. The http:// endpoint is
# a plaintext local registration — no mTLS certs needed (gateway runs disableTls).
if ! command -v openshell >/dev/null 2>&1; then
  log "Installing the openshell CLI"
  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh >/dev/null 2>&1 \
    || warn "openshell CLI install failed — the gateway-driven sandbox lesson won't work in the shell."
fi
if command -v openshell >/dev/null 2>&1; then
  GW_URL="${OPENSHELL_CLI_ENDPOINT:-$(oc -n openshell get route openshell-gateway -o jsonpath='https://{.spec.host}' 2>/dev/null || echo http://openshell.openshell.svc.cluster.local:8080)}"
  log "Registering OpenShell gateway for the workshop shell at ${GW_URL}"
  openshell gateway add "$GW_URL" --local --name cluster >/dev/null 2>&1 || true
  openshell gateway select cluster >/dev/null 2>&1 || true
fi

# --- run it as a systemd service so it survives logout/reboot ---
log "Installing systemd unit openclaw-workshop.service (PORT ${PORT})"
RUN_USER="$(id -un)"
sudo tee /etc/systemd/system/openclaw-workshop.service >/dev/null <<UNIT
[Unit]
Description=OpenClaw workshop site (Next.js + live shell)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${WEB_DIR}
Environment=NODE_ENV=production
Environment=PORT=${PORT}
Environment=HOST=0.0.0.0
Environment=HOME=${HOME}
Environment=LAB_CWD=${REPO_ROOT}
Environment=KUBECONFIG=${KUBECONFIG:-}
ExecStart=$(command -v node) ${WEB_DIR}/server.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-workshop.service
sudo systemctl restart openclaw-workshop.service
sleep 3
code="$(curl -sS -m6 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)"
log "Workshop site: http://<host>:${PORT}/  (local check -> HTTP ${code})"
log "Workshop site is serving on port ${PORT}."
