#!/usr/bin/env bash
# Shared helpers + .env loading. Source this at the top of every phase script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Load .env if present (don't fail if missing — preflight reports what's needed).
load_env() {
  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a; # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"; set +a
    log "Loaded $REPO_ROOT/.env"
  else
    warn "No .env found — copy .env.example to .env and fill it in."
  fi
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required variable '$name' is unset (set it in .env)."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found in PATH."
}
