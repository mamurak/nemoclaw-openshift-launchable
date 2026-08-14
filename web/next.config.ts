import type { NextConfig } from "next";
import createMDX from "@next/mdx";

const nextConfig: NextConfig = {
  pageExtensions: ["ts", "tsx", "mdx"],
  // node-pty is a native addon used only by the custom server (server.mjs) at runtime.
  // @grpc/* are used only by the draft-policy BFF route (server-side) — keep them out of
  // the bundler so proto-loader resolves the vendored .proto files at runtime.
  serverExternalPackages: ["node-pty", "@grpc/grpc-js", "@grpc/proto-loader"],
  async rewrites() {
    const GRAFANA = process.env.GRAFANA_ORIGIN || "http://kps-grafana.monitoring.svc.cluster.local:80";
    return [
      { source: "/grafana", destination: `${GRAFANA}/grafana` },
      { source: "/grafana/:path*", destination: `${GRAFANA}/grafana/:path*` },
    ];
  },
};

const withMDX = createMDX({
  options: {
    remarkPlugins: ["remark-gfm"],
    rehypePlugins: ["rehype-slug"],
  },
});

export default withMDX(nextConfig);
