import path from "node:path";
import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";

// Minimal BFF gRPC client for the OpenShell gateway's openshell.v1.OpenShell service.
// The 0.0.71 CLI doesn't expose a `draft` verb, but the gateway DOES implement the
// draft-policy RPCs (GetDraftPolicy / ApproveDraftChunk / …) — so we call them directly,
// exactly like the OpenShell console does. The workshop gateway is a single-node dev
// instance with no OIDC, so no bearer token is required (confirmed against the live box).
// Protos are vendored in web/proto (copied from NVIDIA/OpenShell).
const PROTO_DIR = path.join(process.cwd(), "proto");
const opts = { keepCase: false, longs: String, enums: String, defaults: true, oneofs: true, includeDirs: [PROTO_DIR] };
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const openshellProto = grpc.loadPackageDefinition(protoLoader.loadSync(path.join(PROTO_DIR, "openshell.proto"), opts)) as any;
const OpenShellService = openshellProto.openshell.v1.OpenShell;
const ENDPOINT = process.env.OPENSHELL_GATEWAY_ENDPOINT || "openshell.openshell.svc.cluster.local:8080";

/** Call a unary openshell.v1.OpenShell method on the gateway. */
export function callGateway<T = unknown>(method: string, request: Record<string, unknown>, timeoutMs = 15000): Promise<T> {
  return new Promise((resolve, reject) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const client = new (OpenShellService as any)(ENDPOINT, grpc.credentials.createInsecure());
    const deadline = new Date(Date.now() + timeoutMs);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (client as any)[method](request, new grpc.Metadata(), { deadline }, (err: grpc.ServiceError | null, resp: T) => {
      try { client.close(); } catch { /* noop */ }
      if (err) reject(err); else resolve(resp);
    });
  });
}
