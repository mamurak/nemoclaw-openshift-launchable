// cluster-telemetry: query an in-cluster observability backend and print a COMPACT summary.
//
// Why this exists: OpenClaw's built-in `web_fetch` tool refuses private/internal/cluster
// addresses (an SSRF guard), so a sealed SRE agent can't use it to read Loki/Prometheus/Tempo
// — which live on `*.svc.cluster.local` (private ClusterIPs). This skill shells out to `curl`
// (an egress-allowed binary) instead, so the network call is still governed by the agent's
// single-backend egress policy — nothing is weakened. The output is summarized to a few lines
// so it never blows the model's context during a tool loop.
//
// Usage (the agent runs this via the `exec` tool) — one or more URLs:
//   node /sandbox/.agents/skills/cluster-telemetry/tq.js '<url>' ['<url2>' …]

const { execFileSync } = require("child_process");

const urls = process.argv.slice(2);
if (!urls.length) { console.error("usage: tq.js <url> [url2 …]"); process.exit(2); }

const cap = (s) => String(s).slice(0, 1200);

let AUTH_ARGS = [];
try {
  const token = require("fs").readFileSync("/sandbox/.monitoring-token", "utf-8").trim();
  if (token) AUTH_ARGS = ["-H", `Authorization: Bearer ${token}`];
} catch {}

function curlFetch(u) {
  return execFileSync("curl", ["-s", "--max-time", "10", "-k", ...AUTH_ARGS, u],
    { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
}

// keep only the labels that matter for an incident — drop noisy ids (container_id, image_id,
// uid, endpoint, instance, job, service…) so each series is short and the signal is visible.
const KEEP = ["namespace", "pod", "deployment", "container", "reason", "image_spec", "image", "phase", "node", "level", "app"];
function project(labels) {
  const o = {};
  for (const k of KEEP) if (labels[k] != null) o[k] = labels[k];
  return Object.keys(o).length ? o : labels;
}

// render one Loki line: if it's a k8s Event (from event-exporter), make it human-readable.
// Events may arrive directly (old Loki sink) or wrapped by the ClusterLogForwarder (stdout
// sink → container log → Loki), in which case the event JSON is inside the `message` field.
function lokiLine(line) {
  try {
    let e = JSON.parse(line);
    if (e && !e.reason && typeof e.message === "string" && e.message.startsWith("{")) {
      try { e = JSON.parse(e.message); } catch { /* not nested JSON */ }
    }
    if (e && (e.reason || e.message)) {
      const o = e.involvedObject || {};
      const obj = o.kind ? `${o.kind}/${o.name}` : (e.metadata && e.metadata.namespace) || "";
      return `[${e.type || "?"}] ${e.reason || ""}: ${String(e.message || "").slice(0, 160)} (${obj})`;
    }
  } catch { /* not JSON — a plain log line */ }
  return String(line).slice(0, 180);
}

function traceDetail(searchUrl, traceID) {
  const detailUrl = searchUrl.replace(/\/search\?.*$/, `/traces/${traceID}`);
  try {
    const td = JSON.parse(curlFetch(detailUrl));
    const spans = [];
    for (const batch of td.batches || []) {
      let svc = "";
      for (const a of (batch.resource || {}).attributes || [])
        if (a.key === "service.name") svc = a.value?.stringValue || "";
      for (const scope of batch.scopeSpans || [])
        for (const span of scope.spans || []) {
          const st = span.status || {};
          const name = span.name || "?";
          const attrs = {};
          for (const a of span.attributes || []) attrs[a.key] = Object.values(a.value || {})[0];
          const dur = (parseInt(span.endTimeUnixNano || "0") - parseInt(span.startTimeUnixNano || "0")) / 1e6;
          let line = `  ${svc}/${name} ${dur.toFixed(0)}ms`;
          if (st.code && st.code !== "STATUS_CODE_UNSET") line += ` status=${st.code}`;
          if (st.message) line += ` err="${st.message.slice(0, 120)}"`;
          if (attrs["peer.service"]) line += ` peer=${attrs["peer.service"]}`;
          spans.push(line);
        }
    }
    return spans;
  } catch { return []; }
}

function summarize(body, url) {
  try {
    const j = JSON.parse(body);
    const d = j.data;
    if (d && Array.isArray(d.result)) {
      const isProm = d.result.some((s) => s.value); // Prometheus vector → metric+value
      if (isProm) {
        const lines = d.result.slice(0, 15).map((s) => `${JSON.stringify(project(s.metric || {}))} => ${s.value ? s.value[1] : ""}`);
        return `status=${j.status || "?"} series=${d.result.length}\n` + cap(lines.join("\n"));
      }
      // Loki streams: flatten [ts,line] across streams, newest first, compact each.
      const entries = [];
      for (const s of d.result) for (const v of s.values || []) entries.push(v);
      entries.sort((a, b) => Number(b[0]) - Number(a[0]));
      const lines = entries.slice(0, 10).map((v) => lokiLine(v[1]));
      return `status=${j.status || "?"} entries=${entries.length}\n` + (cap(lines.join("\n")) || "(no entries)");
    }
    if (Array.isArray(j.traces)) {
      const lines = j.traces.slice(0, 10).map((t) =>
        `${t.traceID || t.traceId || "?"} svc=${t.rootServiceName || "?"} name=${t.rootTraceName || "?"} dur=${t.durationMs ?? "?"}ms`);
      let out = `traces=${j.traces.length}\n` + (cap(lines.join("\n")) || "(no traces)");
      const first = j.traces[0];
      if (first && url) {
        const tid = first.traceID || first.traceId;
        if (tid) {
          const spans = traceDetail(url, tid);
          if (spans.length) out += `\n--- trace ${tid} spans ---\n` + spans.join("\n");
        }
      }
      return out;
    }
    return cap(JSON.stringify(j));
  } catch {
    return cap(body);
  }
}

for (const url of urls) {
  let body;
  try {
    body = curlFetch(url);
  } catch (e) {
    console.log(`=== ${url}\nERR curl: ${(e.stderr || e.message || String(e)).slice(0, 200)}`);
    continue;
  }
  if (urls.length > 1) console.log(`=== ${url.replace(/\?.*$/, "")}`);
  console.log(summarize(body, url));
}
