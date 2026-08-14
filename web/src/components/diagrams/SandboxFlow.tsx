import { ArchExplorer } from "./ArchExplorer";

const NV = "#76b900", PURPLE = "#a78bfa", BLUE = "#6f8fd0", GREEN = "#34d399", AMBER = "#e0a800";

export function SandboxFlow() {
  return (
    <ArchExplorer
      flow
      title="How a new sandbox is born — click each step"
      nodes={[
        { id: "req", label: "1 · Request", sub: "Sandbox CR  or  gateway gRPC", color: BLUE, detail: <>You declare a desired sandbox. Two ways: apply a <code>Sandbox</code> CR with <code>oc</code> (what we do in this lab), or call the <strong>OpenShell gateway</strong> gRPC API (:8080) — which then writes the CR for you. Either way the desired state lands as a <code>sandboxes.agents.x-k8s.io</code> object.</> },
        { id: "reconcile", label: "2 · Reconcile", sub: "agent-sandbox controller", color: NV, detail: <>The <strong>agent-sandbox controller</strong> (ns <code>agent-sandbox-system</code>) watches Sandbox CRs. OpenShell's <strong>compute driver</strong> watches too ("Listing sandboxes from Kubernetes"). When a new CR appears, the controller builds the Pod from the CR's <code>podTemplate</code>.</> },
        { id: "schedule", label: "3 · Schedule", sub: "RBAC · SCC · NetworkPolicy", color: AMBER, detail: <>OpenShift schedules the pod under the namespace's guardrails — RBAC, Security Context Constraints, and any NetworkPolicy (deny-by-default for the agent). The sandbox can only do what policy allows.</> },
        { id: "run", label: "4 · Run", sub: "the agent boots", color: PURPLE, detail: <>The pod starts; the OpenClaw gateway comes up inside the sandbox on its private port :30789 and reads its workspace (IDENTITY/SOUL) + config. The Sandbox CR's status flips to Running.</> },
        { id: "use", label: "5 · Use", sub: "exec in · or the UI", color: GREEN, detail: <>Now you interact: <code>oc exec</code> into the sandbox to run the agent CLI (the <code>openclaw</code> helper), or open its Control UI. Delete the CR and the controller tears the pod down (<code>shutdownPolicy</code>).</> },
      ]}
    />
  );
}
