#!/bin/bash
GW_URL="${OPENSHELL_GATEWAY_ENDPOINT_URL:-http://openshell.openshell.svc.cluster.local:8080}"
openshell gateway add "$GW_URL" --local --name cluster 2>/dev/null || true
openshell gateway select cluster 2>/dev/null || true

ln -sfn /app "$HOME/nemoclaw-openshift-launchable"

cat > "$HOME/nemoclaw-openshift-launchable/.env" <<EOF
OPENCLAW_GATEWAY_PASSWORD=${OPENCLAW_GATEWAY_PASSWORD:-openshell-wad26}
NEMOCLAW_INFERENCE_BASE_URL=${NEMOCLAW_INFERENCE_BASE_URL:-}
NEMOCLAW_MODEL=${NEMOCLAW_MODEL:-}
NEMOCLAW_API_KEY=${NEMOCLAW_API_KEY:-}
EOF

exec node server.mjs
