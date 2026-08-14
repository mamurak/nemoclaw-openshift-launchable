"use client";

type Svc = { label: string; path?: string; routePrefix?: string; suffix?: string };
export const SERVICES: Record<string, Svc> = {
  openclaw:  { label: "OpenClaw UI", routePrefix: "openclaw-ui-openshell" },
  grafana:   { label: "Grafana", path: "/grafana" },
  console:   { label: "OpenShift console", routePrefix: "console-openshift-console", suffix: "/" },
};
export type ServiceName = keyof typeof SERVICES;

function clusterDomain(): string {
  if (typeof window === "undefined") return "";
  const envDomain = (typeof process !== "undefined" && process.env?.NEXT_PUBLIC_CLUSTER_APPS_DOMAIN) || "";
  if (envDomain) return envDomain;
  const host = window.location.hostname;
  const dot = host.indexOf(".");
  return dot > 0 ? host.slice(dot + 1) : "";
}

export function serviceUrl(service: ServiceName): string | null {
  const s = SERVICES[service];
  if (s.path) return s.path;
  const domain = clusterDomain();
  if (!domain) return null;
  return `https://${s.routePrefix}.${domain}${s.suffix ?? ""}`;
}
