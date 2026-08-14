# NemoClaw on OpenShift — Helm Umbrella Chart

[![CI](https://github.com/ansjindal/nemoclaw-openshift-launchable/actions/workflows/ci.yml/badge.svg)](https://github.com/ansjindal/nemoclaw-openshift-launchable/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ansjindal/nemoclaw-openshift-launchable?sort=semver)](https://github.com/ansjindal/nemoclaw-openshift-launchable/releases/latest)
[![License: MIT](https://img.shields.io/github/license/ansjindal/nemoclaw-openshift-launchable)](LICENSE)
![OpenShift](https://img.shields.io/badge/OpenShift-4.x-ee0000?logo=redhatopenshift&logoColor=white)
![NVIDIA](https://img.shields.io/badge/NVIDIA-OpenShell%20·%20OpenClaw-76b900?logo=nvidia&logoColor=white)
![Next.js](https://img.shields.io/badge/site-Next.js%2016-black?logo=nextdotjs)

A Helm umbrella chart that deploys the full NVIDIA OpenShell + OpenClaw agent stack onto an
**existing OpenShift cluster** — with monitoring, an interactive workshop website, and a
capstone SRE-copilot fleet exercise. No GPU needed (inference is remote).

```
OpenShift cluster
  ├─ agent-sandbox CRD + controller (sandboxes.agents.x-k8s.io, pinned v0.4.6)
  ├─ OpenShell gateway (Helm subchart, in-cluster Kubernetes compute driver)
  │    └─ exposed via OpenShift Route (edge TLS + HTTP/2 for gRPC)
  ├─ Monitoring (kube-prometheus-stack + Loki + Tempo, Helm subchart)
  │    └─ Grafana Route at /grafana
  ├─ Workshop web app (Helm subchart, containerized Next.js + terminal bridge)
  │    ├─ openclaw-forward sidecar → OpenClaw Control UI Route
  │    └─ ServiceAccount with scoped RBAC
  └─ OpenClaw agent (agent-sandbox pod, policy-governed)
       ├─ model ──► REMOTE OpenAI-compatible inference endpoint
       └─ Control UI exposed via Route (edge TLS)
```

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| OpenShift 4.x cluster | With `cluster-admin` access |
| `oc` CLI | Logged in (`oc login`) |
| `helm` CLI | v3.x |
| Remote inference endpoint | OpenAI-compatible (`/v1/chat/completions`) |

No GPU, no Red Hat subscription (for the chart itself), and no nested virtualization needed.

## Quick Start

```bash
# Clone and configure
git clone https://github.com/ansjindal/nemoclaw-openshift-launchable.git
cd nemoclaw-openshift-launchable
cp .env.example .env     # fill in inference endpoint vars

# Deploy
./scripts/deploy.sh
```

The deploy script:
1. Runs preflight checks (`oc whoami`, `helm version`, inference endpoints)
2. Creates namespaces (`openshell`, `monitoring`, `demo`) out-of-band
3. Applies the agent-sandbox CRD (pinned v0.4.6)
4. Installs the Helm umbrella chart
5. Optionally deploys the demo app and provisions the OpenClaw agent

After deployment, three Routes are available:
- **Workshop**: `https://workshop-openshell.<apps-domain>/`
- **Grafana**: `https://grafana-monitoring.<apps-domain>/grafana`
- **OpenShift Console**: `https://console-openshift-console.<apps-domain>/`

## Architecture

**What this is (and isn't):** this stack is **OpenShell + OpenClaw on OpenShift**. NemoClaw
itself is a reference layer (CLI + blueprint + policies) with **no gateway of its own** — the
gateway *is* OpenShell's. The `nemoclaw` CLI is **not used** here: this repo deploys via
Helm + CRD directly.

| "Gateway" | Port | Role |
|-----------|------|------|
| **OpenShell gateway** | 8080 | sandbox control plane (= "NemoClaw's gateway") |
| **OpenClaw gateway**  | 18789 | the agent's own control UI, inside the sandbox |

The OpenClaw agent runs under a **deny-by-default policy** at two layers:
- **L4:** Kubernetes `NetworkPolicy` — allows DNS + intra-cluster + external HTTPS only
- **L7:** OpenShell's per-binary/method/path schema in [`policies/`](policies/)

## Chart Structure

```
chart/
├── Chart.yaml           # umbrella chart
├── values.yaml          # global.clusterAppsDomain, storageClassName, etc.
└── charts/
    ├── openshell/       # wraps oci://ghcr.io/nvidia/openshell/helm-chart
    ├── monitoring/      # wraps kube-prometheus-stack + loki + tempo
    └── workshop/        # containerized Next.js web app
```

### Key Design Decisions

- **Namespaces created out-of-band** — `helm uninstall` deletes Helm-managed namespaces, destroying non-Helm resources in them.
- **agent-sandbox CRD applied out-of-band** — CRDs are cluster-scoped and shouldn't be owned by a namespaced release.
- **Demo app stays as Kustomize** — the incident route dynamically applies/deletes it; dual Helm ownership would conflict.
- **Route uses edge TLS** (not passthrough) — the gateway runs with `disableTls: true`, so there's no TLS to pass through.

## Configuration

```bash
cp .env.example .env
```

| Variable | Required | Description |
|----------|----------|-------------|
| `NEMOCLAW_INFERENCE_BASE_URL` | Yes | Remote inference endpoint base URL |
| `NEMOCLAW_MODEL` | Yes | Model name for inference |
| `NEMOCLAW_API_KEY` | Yes | API key for inference |
| `CLUSTER_APPS_DOMAIN` | No | Auto-detected from the cluster |
| `OPENCLAW_GATEWAY_PASSWORD` | No | Default: `openclaw` |
| `PROVISION_AGENT` | No | Set `true` to auto-create the OpenClaw agent |

## Teardown

```bash
helm -n openshell uninstall nemoclaw
oc delete -k manifests/demo-app/ --ignore-not-found
for ns in openshell monitoring demo; do oc delete namespace "$ns"; done
```

## References

- [OpenShell](https://github.com/NVIDIA/OpenShell) · [Helm chart](https://github.com/NVIDIA/OpenShell/blob/main/deploy/helm/openshell/README.md)
- [NemoClaw](https://github.com/NVIDIA/NemoClaw)
- [agent-sandbox CRD](https://github.com/kubernetes-sigs/agent-sandbox)
