import { ArchExplorer } from "./ArchExplorer";

const RH = "#ff4d4d", NV = "#76b900", BLUE = "#6f8fd0", PURPLE = "#a78bfa", AMBER = "#e0a800", CYAN = "#22d3ee";

export function SecurityLayers() {
  return (
    <ArchExplorer
      title="Defense in depth — what bounds the agent (click each layer)"
      nodes={[
        { id: "ns", label: "Namespace + RBAC", sub: "OpenShift", color: RH, detail: <>The agent lives in its own namespace with a scoped ServiceAccount. RBAC decides what Kubernetes verbs that identity may use — by default, almost nothing outside its sandbox.</> },
        { id: "scc", label: "Security Context Constraints", sub: "non-root · drop caps", color: RH, detail: <>OpenShift SCCs force the agent to run <strong>non-root</strong> (UID 1000), with <code>allowPrivilegeEscalation: false</code> and <strong>all Linux capabilities dropped</strong>. No host mounts, no privileged mode.</> },
        { id: "netpol", label: "NetworkPolicy", sub: "deny-by-default egress", color: BLUE, detail: <>A deny-by-default <code>NetworkPolicy</code> (<code>openclaw-deny-by-default</code>) limits the sandbox to DNS + HTTPS egress and router-only ingress — so a compromised agent can't phone home or scan the cluster.</> },
        { id: "l7", label: "OpenShell L7 policy", sub: "per-binary/method/path", color: NV, detail: <>When running under OpenShell's supervisor, a deny-by-default <strong>L7 policy</strong> (the schema in <code>policies/</code>) controls which binaries/methods/paths the agent may use — far finer-grained than L4.</> },
        { id: "mtls", label: "mTLS + privacy router", sub: "OpenShell", color: CYAN, detail: <>OpenShell uses mTLS between components, and its <strong>inference privacy router</strong> means the agent never holds the real upstream model key — the gateway injects it. Compromise the agent, you still don't get the key.</> },
        { id: "runtime", label: "Runtime isolation", sub: "pod · (gVisor optional)", color: PURPLE, detail: <>Standard pod/container isolation here. The full OpenShell product can add a <strong>gVisor (runsc) RuntimeClass</strong> for kernel-level syscall sandboxing — stronger isolation optionally enabled on the OpenShift cluster, the same posture used in production fleets.</> },
      ]}
    />
  );
}
