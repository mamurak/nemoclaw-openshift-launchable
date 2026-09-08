import { readFileSync } from "fs";

const TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token";

let cachedToken = "";
let cachedAt = 0;

export function monitoringToken(): string {
  const now = Date.now();
  if (cachedToken && now - cachedAt < 60_000) return cachedToken;
  try {
    cachedToken = readFileSync(TOKEN_PATH, "utf-8").trim();
    cachedAt = now;
  } catch {
    cachedToken = "";
  }
  return cachedToken;
}

export function monitoringHeaders(): Record<string, string> {
  const token = monitoringToken();
  return token ? { Authorization: `Bearer ${token}` } : {};
}
