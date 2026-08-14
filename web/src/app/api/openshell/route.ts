import { NextResponse } from "next/server";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

// Live OpenShell data for the learning UI. The web server runs on the instance (as the
// same user that drives the lab), so it reads the gateway's state straight from the
// cluster + the openshell CLI. READ-ONLY, fixed commands; the only variable is a sandbox
// name, which we validate against a strict pattern and pass as an argv element (execFile,
// no shell) → nothing injectable. (Egress access-request approvals live in /api/drafts.)

const run = promisify(execFile);
const NS = "openshell";
const KUBECONFIG = process.env.KUBECONFIG || "";
const env = { ...process.env, ...(KUBECONFIG ? { KUBECONFIG } : {}), PATH: `${process.env.PATH ?? ""}:/usr/local/bin:/usr/bin` };
const validName = (n: string) => /^[a-z0-9][a-z0-9-]{0,40}$/.test(n);

async function oc(args: string[]) {
  const { stdout } = await run("oc", ["-n", NS, ...args], { env, timeout: 8000, maxBuffer: 4 << 20 });
  return JSON.parse(stdout);
}
async function openshell(args: string[]) {
  const { stdout } = await run("openshell", args, { env, timeout: 10000, maxBuffer: 4 << 20 });
  return stdout;
}
async function openshellJson(args: string[]) {
  const { stdout } = await run("openshell", args, { env, timeout: 10000, maxBuffer: 4 << 20 });
  return JSON.parse(stdout);
}

// The gateway's inference route (active provider + model) and the registered providers.
// `provider list -o json` exposes only the credential/config KEY NAMES — never the secret
// values — so this is safe to surface read-only in the UI.
type Provider = { name: string; type: string; credential_keys?: string[]; config_keys?: string[] };
async function getInference() {
  const [routeText, providers] = await Promise.all([
    openshell(["inference", "get"]).catch(() => ""),
    openshellJson(["provider", "list", "-o", "json"]).catch(() => [] as Provider[]),
  ]);
  const gw = routeText.replace(/\x1b\[[0-9;]*m/g, "").split(/System inference:/i)[0];
  const provider = /Provider:\s*(\S+)/.exec(gw)?.[1] ?? null;
  const model = /Model:\s*(\S+)/.exec(gw)?.[1] ?? null;
  const version = /Version:\s*(\S+)/.exec(gw)?.[1] ?? null;
  return {
    configured: !!(provider && model),
    provider, model, version,
    providers: (providers as Provider[]).map((p) => ({
      name: p.name, type: p.type,
      credentialKeys: p.credential_keys ?? [], configKeys: p.config_keys ?? [],
    })),
  };
}

export const dynamic = "force-dynamic";

export async function GET(req: Request) {
  const url = new URL(req.url);
  const logsFor = url.searchParams.get("logs");
  const policyFor = url.searchParams.get("policy");

  try {
    // --- per-sandbox logs (the gateway/sandbox audit + egress feed) ---
    if (logsFor) {
      if (!validName(logsFor)) return NextResponse.json({ ok: false, error: "bad name" });
      const src = url.searchParams.get("source") ?? "all";
      const source = ["gateway", "sandbox", "all"].includes(src) ? src : "all";
      // Optional line count (the Policy-decisions view pulls a large tail, since egress
      // decisions are sparse and a single skill install can spew >120 lines after them).
      const n = Math.min(Math.max(parseInt(url.searchParams.get("n") || "120", 10) || 120, 1), 4000);
      const out = await openshell(["logs", logsFor, "-n", String(n), "--source", source]).catch((e) => `(${e instanceof Error ? e.message : e})`);
      return NextResponse.json({ ok: true, name: logsFor, source, text: out });
    }

    // --- per-sandbox effective policy (full YAML: filesystem, process, network rules) ---
    if (policyFor) {
      if (!validName(policyFor)) return NextResponse.json({ ok: false, error: "bad name" });
      const out = await openshell(["policy", "get", policyFor, "--full"]).catch((e) => `(${e instanceof Error ? e.message : e})`);
      return NextResponse.json({ ok: true, name: policyFor, text: out });
    }

    // --- default: gateway health + the sandbox fleet + the inference route ---
    const [sb, pods, inference] = await Promise.all([
      oc(["get", "sandboxes.agents.x-k8s.io", "-o", "json"]).catch(() => ({ items: [] })),
      oc(["get", "pods", "-o", "json"]).catch(() => ({ items: [] })),
      getInference().catch(() => null),
    ]);
    type Pod = { metadata: { name: string }; status?: { phase?: string; containerStatuses?: { ready?: boolean; restartCount?: number }[] } };
    const podByName = new Map<string, Pod>();
    for (const p of (pods.items ?? []) as Pod[]) podByName.set(p.metadata.name, p);
    type SB = { metadata: { name: string; creationTimestamp?: string }; status?: { phase?: string } };
    const sandboxes = ((sb.items ?? []) as SB[]).map((s) => {
      const pod = podByName.get(s.metadata.name);
      const cs = pod?.status?.containerStatuses ?? [];
      return {
        name: s.metadata.name,
        phase: s.status?.phase || pod?.status?.phase || "—",
        ready: cs.length ? cs.every((c) => c.ready) : false,
        restarts: cs.reduce((n, c) => n + (c.restartCount ?? 0), 0),
        created: s.metadata.creationTimestamp ?? null,
      };
    });
    let gateway = { ready: false, version: null as string | null };
    try {
      const ss = await oc(["get", "statefulset", "openshell", "-o", "json"]);
      gateway.ready = (ss.status?.readyReplicas ?? 0) >= 1;
      const img: string = ss.spec?.template?.spec?.containers?.[0]?.image ?? "";
      const m = /gateway:(\S+)/.exec(img);
      gateway.version = m ? m[1] : null;
    } catch {}
    return NextResponse.json({ ok: true, gateway, sandboxes, inference, at: new Date().toISOString() });
  } catch (e) {
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message : String(e) });
  }
}
