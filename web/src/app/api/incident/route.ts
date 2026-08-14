import { NextResponse } from "next/server";
import { spawn } from "node:child_process";

// Part VI capstone — the Incident Lab. The demo is an instrumented app (shop-app) driven by a
// continuous loadgen, so logs/metrics/traces are always live. The incident is an APPLICATION
// fault you inject at runtime (the payment path starts returning 503s) — visible in the app's
// own telemetry. The agents only DIAGNOSE (read-only); the human approves the remediation
// (clearing the fault), which this route applies. In production that's a git revert ArgoCD syncs.

const KUBECONFIG = process.env.KUBECONFIG || "";
const env = { ...process.env, ...(KUBECONFIG ? { KUBECONFIG } : {}), PATH: `${process.env.PATH ?? ""}:/usr/local/bin:/usr/bin` };
const NS = "demo", APP = "shop-app";
const KDIR = process.env.DEMO_APP_MANIFESTS || "/app/manifests/demo-app";
const PROM = process.env.PROM_HOST || "kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090";

function kubectl(args: string[], timeoutMs = 60_000): Promise<{ code: number | null; out: string }> {
  return new Promise((resolve) => {
    const c = spawn("kubectl", args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let out = ""; c.stdout.on("data", (d) => (out += d)); c.stderr.on("data", (d) => (out += d));
    const t = setTimeout(() => c.kill("SIGTERM"), timeoutMs);
    c.on("close", (code) => { clearTimeout(t); resolve({ code, out: out.trim() }); });
    c.on("error", (e) => { clearTimeout(t); resolve({ code: 1, out: String(e) }); });
  });
}

// The host can't reach in-cluster ClusterIPs, so we curl from inside the cluster via the
// loadgen pod (it has curl) — to read Prometheus from inside the cluster.
function inCluster(url: string) {
  return kubectl(["-n", NS, "exec", `deploy/loadgen`, "--", "curl", "-s", "-m", "6", url], 20_000);
}
async function promRps(): Promise<Record<string, number>> {
  const r = await inCluster(`http://${PROM}/api/v1/query?query=${encodeURIComponent("sum by (code) (rate(shop_requests_total[30s]))")}`);
  const rps: Record<string, number> = {};
  try { for (const s of JSON.parse(r.out)?.data?.result ?? []) rps[s.metric.code] = parseFloat(s.value[1]) || 0; } catch { /* */ }
  return rps;
}

async function health() {
  const dep = await kubectl(["-n", NS, "get", "deploy", APP, "-o", "jsonpath={.status.readyReplicas}/{.spec.replicas}"]);
  const exists = dep.code === 0;
  // live pods in the demo namespace (shop-app + payments + loadgen): "name=Phase,WaitingReason"
  const pods = await kubectl(["-n", NS, "get", "pods", "-o",
    "jsonpath={range .items[*]}{.metadata.name}{'='}{.status.phase}{','}{range .status.containerStatuses[*]}{.state.waiting.reason}{end}{'\\n'}{end}"]);
  if (!exists) return { exists: false, healthy: false, pods: pods.out };
  // the fault state is REAL: is the payments dependency up? (scaled to 0 = the injected outage)
  const pay = await kubectl(["-n", NS, "get", "deploy", "payments", "-o", "jsonpath={.status.readyReplicas}"]);
  const paymentsUp = (parseInt(pay.out, 10) || 0) > 0;
  const rps = await promRps();
  const success = rps["200"] || 0;
  const errors = Object.entries(rps).filter(([c]) => c.startsWith("5")).reduce((a, [, v]) => a + v, 0);
  const total = success + errors;
  const r2 = (n: number) => Math.round(n * 100) / 100;
  return {
    exists: true, pods: pods.out, paymentsUp, fault: paymentsUp ? "none" : "payments-down",
    healthy: paymentsUp && errors < 0.05,
    successRps: r2(success), errorRps: r2(errors), totalRps: r2(total),
    errorPct: total > 0 ? Math.round((100 * errors) / total) : 0,
  };
}

export async function GET() {
  return NextResponse.json({ ok: true, ...(await health()) });
}

export async function POST(req: Request) {
  const body = await req.json().catch(() => ({}));
  const { action } = body;
  try {
    if (action === "deploy") {
      const a = await kubectl(["apply", "-k", KDIR]);
      await kubectl(["-n", NS, "rollout", "status", `deploy/${APP}`, "--timeout=90s"]);
      return NextResponse.json({ ok: a.code === 0, action, out: a.out, ...(await health()) });
    }
    if (action === "break") {
      // a REAL dependency outage: scale the payments deployment to 0. shop-app's checkout makes a
      // real HTTP call to payments → now connection-refused → genuine 503s. Nothing artificial:
      // the failure emerges from a real downstream being gone (a common, real production incident).
      const a = await kubectl(["-n", NS, "scale", "deploy/payments", "--replicas=0"]);
      await kubectl(["-n", NS, "wait", "--for=delete", "pod", "-l", "app=payments", "--timeout=30s"]).catch(() => ({}));
      return NextResponse.json({ ok: a.code === 0, action, note: "scaled the payments dependency to 0 — checkout's real calls to it now fail", out: a.out, ...(await health()) });
    }
    if (action === "fix") {
      // the human-approved remediation: a REAL fix — bring the payments dependency back up.
      const a = await kubectl(["-n", NS, "scale", "deploy/payments", "--replicas=1"]);
      await kubectl(["-n", NS, "rollout", "status", "deploy/payments", "--timeout=90s"]);
      return NextResponse.json({ ok: a.code === 0, action, applied: "scaled payments back to 1 (restored the dependency)", out: a.out, ...(await health()) });
    }
    if (action === "teardown") {
      const a = await kubectl(["delete", "-k", KDIR, "--ignore-not-found"]);
      return NextResponse.json({ ok: a.code === 0, action, out: a.out });
    }
    return NextResponse.json({ ok: false, error: "action must be deploy|break|fix|teardown" }, { status: 400 });
  } catch (e) {
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message : String(e) }, { status: 500 });
  }
}
