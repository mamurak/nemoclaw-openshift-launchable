# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Helm umbrella chart that deploys the NVIDIA OpenShell + OpenClaw agent stack onto an existing OpenShift cluster, with the OpenShift operator-based observability stack (Prometheus/Thanos, Loki, Tempo, OTEL Collector), standalone Grafana, and an interactive Next.js workshop website. Inference is remote (no GPU needed). The chart installs three subcharts: `openshell` (gateway + sandbox CRD), `monitoring` (Grafana + event-exporter), and `workshop` (the web app + terminal bridge). The observability operators and backends are deployed separately via `scripts/15-observability.sh`.

## Build & CI Commands

### Workshop web app (`web/`)
```bash
cd web && npm ci                 # install deps (includes native node-pty addon)
cd web && npm run build          # production build — typechecks TS + parses all MDX lessons
cd web && npm run dev            # dev server on :3000 (uses custom server.mjs, not next dev)
cd web && npm run lint           # eslint
cd web && npm start              # production mode (NODE_ENV=production node server.mjs)
```

### Tests (`web/tests/`)
```bash
cd web && npm test                # smoke tests — local dev server (auto-started)
cd web && npm run test:e2e        # E2E tests — live OpenShift deployment
cd web && npm run test:ui         # interactive Playwright UI (both projects)

# E2E against a different cluster:
cd web && E2E_BASE_URL=https://workshop-openshell.apps.example.com npx playwright test --project=e2e
```

Two Playwright projects:
- **smoke** (`tests/smoke.spec.ts`, 6 tests) — runs against the local dev server (auto-started by Playwright). Covers homepage render, curriculum nav, all lesson pages load, next/prev navigation, 404 handling.
- **e2e** (`tests/e2e.spec.ts`, 75 tests) — runs against a live OpenShift deployment. Covers everything in smoke plus: header nav links (Live, Approvals, Links dropdown), theme toggle, sidebar lesson click-through, lab shell button on `hasLab` lessons, all 7 API routes (GET schema validation + POST 400 on invalid actions), Grafana proxy redirect, approvals page render, error handling, and **"Run in shell" command verification** across all 21 lab lessons (extracts code blocks from each page, skips mutating/env-dependent/openshell-CLI commands, executes read-only `oc` commands via `/api/check`, and asserts on exit code + error patterns in stderr/stdout). Set `E2E_BASE_URL` to target a different cluster.

### Helm chart (`chart/`)
```bash
helm lint chart/
helm template nemoclaw chart/ --set global.clusterAppsDomain=apps.test.example.com
```

### Docker image (workshop)
```bash
docker build -f web/Dockerfile .   # build from repo root
```

### Shell scripts
```bash
shellcheck --severity=error --external-sources scripts/deploy.sh scripts/00-preflight.sh scripts/15-observability.sh scripts/45-openclaw.sh scripts/fleet.sh scripts/lib/common.sh scripts/lib/operator-manager.sh scripts/lib/enable-uwm.sh
```

### CI runs five jobs (`.github/workflows/ci.yml`)
1. **web-build** — `npm ci && npm run build` in `web/` (Node 20)
2. **shellcheck** — lint shell scripts at error severity
3. **yaml-syntax** — parse all YAML in `manifests/`, `policies/`, `deploy/`, `chart/`
4. **helm-lint** — `helm lint` + `helm template` the umbrella chart
5. **docker-build** — build the workshop Dockerfile (builder stage only)

## Architecture

### Deployment (`scripts/deploy.sh`)
Entry point for deploying the stack. It:
1. Runs preflight checks (`oc whoami`, `helm version`, `yq`, `jq`, `envsubst`, inference endpoints)
2. Deploys the OpenShift observability stack via `scripts/15-observability.sh` (operators + MinIO + Tempo + Loki + OTEL)
3. Creates namespaces out-of-band (not Helm-managed — `helm uninstall` would delete them)
4. Applies the agent-sandbox CRD out-of-band (cluster-scoped, pinned to v0.4.6)
5. Runs `helm upgrade --install` for the openshell + workshop subcharts
6. Installs the monitoring subchart (Grafana + event-exporter) as a separate release
7. Optionally deploys the demo app via Kustomize and provisions the OpenClaw agent fleet

### Observability stack (`scripts/15-observability.sh`)
Deploys the OpenShift operator-based monitoring backend:
1. Installs 5 operators via `scripts/lib/operator-manager.sh`: Cluster Observability, OpenTelemetry, Tempo, Logging, Loki
2. Enables User Workload Monitoring via `scripts/lib/enable-uwm.sh`
3. Deploys MinIO (S3 backend for Loki + Tempo) in `observability-hub` namespace
4. Deploys TempoStack, LokiStack + ClusterLogForwarder, OTEL Collector via Helm charts in `deploy/observability/`

### Helm chart (`chart/`)
Umbrella chart with three subcharts:
- **openshell** — wraps the upstream `oci://ghcr.io/nvidia/openshell/helm-chart`. Adds SCC grants, an OpenShift Route (edge TLS + HTTP/2 for gRPC), sandbox image prepull Job, and the Verdaccio skill registry.
- **monitoring** — standalone Grafana + event-exporter. Grafana datasources point at the OpenShift monitoring backends (Thanos Querier, Loki gateway, Tempo gateway) with bearer token auth. Includes the Agent Fleet dashboard.
- **workshop** — the containerized Next.js web app. Deployment with an `openclaw-forward` sidecar, Service (ports 3000 + 8789), two Routes (workshop + OpenClaw UI), ServiceAccount + RBAC.

### Monitoring endpoints
All query endpoints require bearer token auth (SA token with `cluster-monitoring-view` ClusterRole).

| Signal | Service | Port | Path prefix |
|---|---|---|---|
| Metrics (PromQL) | `thanos-querier.openshift-monitoring` | 9091 | `/api/v1/query` |
| Logs (application) | `logging-loki-gateway-http.openshift-logging` | 8080 | `/api/logs/v1/application/loki/api/v1/` |
| Logs (infrastructure) | `logging-loki-gateway-http.openshift-logging` | 8080 | `/api/logs/v1/infrastructure/loki/api/v1/` |
| Traces (query) | `tempo-tempostack-gateway.observability-hub` | 8080 | `/api/traces/v1/dev/tempo/api/` |
| Traces (OTLP ingest) | `otel-collector-collector.observability-hub` | 4318 | `/v1/traces` |

### Workshop web app (`web/`)
Next.js 16 with MDX content. Custom server (`server.mjs`) adds a WebSocket-based terminal bridge (`/ws/term`) using node-pty. In-cluster, `oc`/`kubectl` auto-detect the projected ServiceAccount token — no static kubeconfig needed.

Key pieces:
- `src/lib/curriculum.ts` — defines all parts/lessons (the nav tree); each lesson maps to `src/content/<slug>.mdx`
- `src/lib/monitoring.ts` — reads SA token for bearer auth to OpenShift monitoring backends
- `src/lib/routes.ts` — constructs service URLs from OpenShift Routes (replaces the old Brev URL module)
- `src/lib/gateway-grpc.ts` — gRPC client for the OpenShell gateway (uses vendored protos in `web/proto/`)
- `src/app/api/` — API routes for device pairing, incident lab, fleet orchestration, live OpenShell data
- `next.config.ts` — MDX plugin setup, `serverExternalPackages` for node-pty and gRPC, Grafana proxy rewrite at `/grafana`

### Demo app (`manifests/demo-app/`)
NOT Helm-managed. The incident route (`api/incident/route.ts`) dynamically applies/deletes it via `kubectl apply -k` / `kubectl delete -k`. Uses Kustomize `configMapGenerator` with hash-suffixed names. Two distinct demo apps exist:
1. `manifests/demo-app/` — instrumented shop-app with OTEL tracing (incident lab)
2. `manifests/openclaw/demo-app.yaml` — simpler nginx shop (fleet capstone)

### Fleet system (`scripts/fleet.sh` + `fleet.txt`)
Brings up specialist agents (logs, metrics, traces, events, analyst) from a spec file. Each agent gets a per-role deny-by-default policy, identity files, optional skills, and a monitoring auth token for OpenShift backends. Auto-discovers the gateway Route URL.

### Policies (`policies/`)
OpenShell deny-by-default policies in YAML and JSON. Keep them in sync:
```bash
python3 -c "import yaml,json,sys; json.dump(yaml.safe_load(open('policies/openclaw-sandbox.yaml')), sys.stdout, indent=2)" > policies/openclaw-sandbox.json
```

## Key Gotchas

- **agent-sandbox CRD must be v0.4.6** — v0.5.0+ uses v1beta1 API; gateway 0.0.71 speaks v1alpha1 only. Mismatch causes `PERMISSION_DENIED` on supervisor bootstrap.
- **OpenShell Route needs edge TLS + HTTP/2** — gateway runs with `disableTls: true`, so passthrough won't work. The `haproxy.router.openshift.io/enable-http2: "true"` annotation is required for gRPC.
- JWT secret mode must be `0444` (OpenShift assigns random UID that can't read `0400`).
- `ws://127.0.0.1:30789` in API routes is correct — those commands run inside the sandbox via `openshell sandbox exec`, where port 30789 is the local OpenClaw gateway.
- The `nemoclaw` CLI is **not used** — this repo deploys via Helm + CRD directly.
- **Monitoring backends require bearer token auth** — all queries to Thanos Querier, Loki gateway, and Tempo gateway need an SA token with `cluster-monitoring-view`. The `monitoring-reader` SA in the `monitoring` namespace provides this. Fleet agents get a 24h token injected at sandbox creation.
- **Loki multi-tenant paths** — application logs use `/api/logs/v1/application/...`, infrastructure logs use `/api/logs/v1/infrastructure/...`. Both the `logs` agent and `events` agent query the application tenant. The event-exporter writes K8s events to stdout; the ClusterLogForwarder ships them to Loki as application logs under `{kubernetes_namespace_name="monitoring",kubernetes_container_name="event-exporter"}`.
- **Event-exporter uses stdout, not direct Loki push** — the upstream event-exporter v1.7 Loki sink has a bug where `Send()` uses `http.DefaultClient` (no timeout), causing pushes to hang and block all subsequent events. The stdout receiver bypasses this; events flow through the ClusterLogForwarder pipeline instead.
