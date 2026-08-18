import Link from "next/link";
import { Activity } from "lucide-react";
import { ThemeToggle } from "./ThemeToggle";
import { InstanceLinks } from "./InstanceLinks";
import { ApprovalsNav } from "./ApprovalsNav";

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-40 flex h-14 items-center gap-3 border-b border-[var(--color-line)] bg-[rgba(10,12,16,0.82)] px-5 backdrop-blur">
      <Link href="/" className="flex items-center gap-2 font-bold tracking-tight">
        <span>🦞</span>
        <span className="hidden sm:inline">
          <span className="text-[var(--color-fg-dim)]">OpenClaw</span>
          <span className="text-[var(--color-fg-mut)]"> · </span>
          <span className="text-[var(--color-nv-bright)]">OpenShell</span>
          <span className="text-[var(--color-fg-mut)]"> on </span>
          <span className="text-[var(--color-rh-bright)]">OpenShift</span>
        </span>
        <span className="sm:hidden">OpenClaw on OpenShift</span>
      </Link>
      <div className="ml-auto flex items-center gap-2 text-[0.72rem] text-[var(--color-fg-mut)]">
        <Link href="/learn/live" title="Live OpenShell — gateway, sandboxes, policies, logs"
          className="inline-flex items-center gap-1.5 rounded-full border border-[var(--color-line-2)] px-2.5 py-1 transition hover:border-[var(--color-nv-dim)] hover:text-[var(--color-nv-bright)]">
          <Activity size={13} /> <span className="hidden sm:inline">Live</span>
        </Link>
        <ApprovalsNav />
        <InstanceLinks />
        <span className="rounded-full border border-[rgba(238,0,0,0.35)] px-2.5 py-1 text-[var(--color-rh-bright)]">Red Hat</span>
        <span className="rounded-full border border-[rgba(118,185,0,0.35)] px-2.5 py-1 text-[var(--color-nv-bright)]">OpenShell</span>
        <ThemeToggle />
      </div>
    </header>
  );
}
