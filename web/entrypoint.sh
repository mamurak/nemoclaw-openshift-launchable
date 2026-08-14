#!/bin/bash
GW_URL="${OPENSHELL_GATEWAY_ENDPOINT_URL:-http://openshell.openshell.svc.cluster.local:8080}"
openshell gateway add "$GW_URL" --local --name cluster 2>/dev/null || true
openshell gateway select cluster 2>/dev/null || true
exec node server.mjs
