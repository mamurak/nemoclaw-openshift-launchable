// Custom Next.js server that also bridges a browser terminal to a real shell
// (node-pty) over WebSocket. The shell starts with the ServiceAccount token
// auto-detected by oc/kubectl (in-cluster) and an `openclaw` helper that execs
// into the agent pod — so learners run `oc ...` and `openclaw devices list/approve`
// for real.
import { createServer } from "node:http";
import { parse } from "node:url";
import { spawn } from "node:child_process";
import next from "next";
import { WebSocketServer } from "ws";
import pty from "node-pty";

const dev = process.env.NODE_ENV !== "production";
const hostname = process.env.HOST || "0.0.0.0";
const port = parseInt(process.env.PORT || "3000", 10);

const LAB_CWD = process.env.LAB_CWD || `/app`;
const LAB_KUBECONFIG = process.env.KUBECONFIG || "";
const LAB_RC = process.env.LAB_RC || `${process.cwd()}/lab/labrc`;
const MAX_SESSIONS = parseInt(process.env.LAB_MAX_SESSIONS || "25", 10);

const app = next({ dev, hostname, port });
const handle = app.getRequestHandler();
let sessions = 0;
await app.prepare();

// Run an author-supplied lab "Check" command and report pass/fail by exit code.
// The client already has a full interactive shell over /ws/term, so this adds no
// new exposure on this single-user lab box.
function runCheck(cmd) {
  return new Promise((resolve) => {
    const p = spawn("/bin/bash", ["-lc", cmd], {
      cwd: LAB_CWD,
      env: { ...process.env, ...(LAB_KUBECONFIG ? { KUBECONFIG: LAB_KUBECONFIG } : {}), LAB_CWD },
      timeout: 25000,
    });
    let out = "", errs = "";
    p.stdout.on("data", (d) => { out += d; });
    p.stderr.on("data", (d) => { errs += d; });
    p.on("close", (code) => resolve({ exitCode: code ?? 1, stdout: out.slice(0, 4000), stderr: errs.slice(0, 4000) }));
    p.on("error", (e) => resolve({ exitCode: 1, stdout: "", stderr: String(e) }));
  });
}

const server = createServer((req, res) => {
  if (req.method === "POST" && (req.url || "").split("?")[0] === "/api/check") {
    let body = "";
    req.on("data", (c) => { body += c; if (body.length > 8192) req.destroy(); });
    req.on("end", async () => {
      try {
        const { cmd } = JSON.parse(body || "{}");
        if (!cmd || typeof cmd !== "string") {
          res.writeHead(400, { "content-type": "application/json" });
          res.end(JSON.stringify({ exitCode: 1, stderr: "missing cmd" }));
          return;
        }
        const r = await runCheck(cmd);
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(r));
      } catch (e) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ exitCode: 1, stderr: String(e) }));
      }
    });
    return;
  }
  handle(req, res, parse(req.url, true));
});

const wss = new WebSocketServer({ noServer: true });

server.on("upgrade", (req, socket, head) => {
  const { pathname } = parse(req.url || "");
  if (pathname !== "/ws/term") { socket.destroy(); return; }
  wss.handleUpgrade(req, socket, head, (ws) => {
    if (sessions >= MAX_SESSIONS) {
      ws.send("\r\n\x1b[31mToo many active lab sessions. Try again shortly.\x1b[0m\r\n");
      ws.close();
      return;
    }
    sessions++;
    const shell = pty.spawn("/bin/bash", ["--rcfile", LAB_RC, "-i"], {
      name: "xterm-256color",
      cols: 100,
      rows: 28,
      cwd: LAB_CWD,
      env: { ...process.env, ...(LAB_KUBECONFIG ? { KUBECONFIG: LAB_KUBECONFIG } : {}), TERM: "xterm-256color", LAB_CWD, OCLAW_LAB: "1" },
    });
    const onData = (d) => { if (ws.readyState === ws.OPEN) ws.send(d); };
    shell.onData(onData);
    shell.onExit(() => ws.readyState === ws.OPEN && ws.close());

    ws.isAlive = true;
    ws.on("pong", () => { ws.isAlive = true; });
    const keepalive = setInterval(() => {
      if (ws.readyState !== ws.OPEN) return;
      if (ws.isAlive === false) { try { ws.terminate(); } catch {} return; }
      ws.isAlive = false;
      try { ws.ping(); } catch {}
    }, 20000);

    ws.on("message", (raw) => {
      const msg = raw.toString();
      if (msg.startsWith("\x00resize:")) {
        const [, cols, rows] = msg.split(":");
        try { shell.resize(parseInt(cols, 10) || 100, parseInt(rows, 10) || 28); } catch {}
      } else {
        shell.write(msg);
      }
    });
    ws.on("close", () => { clearInterval(keepalive); try { shell.kill(); } catch {} sessions = Math.max(0, sessions - 1); });
  });
});

server.listen(port, hostname, () => {
  console.log(`> OpenClaw workshop ready on http://${hostname}:${port}  (shell bridge: /ws/term)`);
});
