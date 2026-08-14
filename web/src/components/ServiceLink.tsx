"use client";
import { type ReactNode } from "react";
import { ExternalLink } from "lucide-react";
import { serviceUrl, SERVICES, type ServiceName } from "@/lib/routes";

export function ServiceLink({ service, children }: { service: ServiceName; children?: ReactNode }) {
  const href = serviceUrl(service);
  const label = children ?? `Open ${SERVICES[service].label}`;

  return (
    <a href={href ?? "#"} target="_blank" rel="noreferrer"
      className="inline-flex items-center gap-1 font-medium text-[var(--color-nv-bright)] underline decoration-[var(--color-nv-dim)] underline-offset-2 hover:decoration-[var(--color-nv-bright)]">
      {label} <ExternalLink size={13} />
    </a>
  );
}
