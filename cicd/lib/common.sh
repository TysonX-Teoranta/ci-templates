#!/usr/bin/env bash
# common.sh — shared helpers for the central CICD v2 spine (contract C178289477824693).
# Sourced by every cicd/*.sh script: strict mode, logging, dry-run plumbing, and a
# flat domains.yml registry reader (awk-based, no yq dependency).
# Fleet V3: strict mode, header, -v verbose, --dry-run, offline-testable.

# Guard against double-sourcing. The exit is the fallback for direct execution
# (return fails outside a sourced context); shellcheck's unreachable warning here
# is a false positive.
if [ -n "${_CICD_COMMON_SOURCED:-}" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi
_CICD_COMMON_SOURCED=1

set -uo pipefail
: "${HOME:=/home/deploy}"   # systemd HOME can be unbound; pin so set -u refs resolve.

# --- Globals -----------------------------------------------------------------
# CICD_ROOT = the cicd/ dir (this file lives in cicd/lib/common.sh).
CICD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# REPO_ROOT = the scaffold root (cicd/ sits one level below it, next to domains.yml).
REPO_ROOT="$(cd "$CICD_ROOT/.." && pwd)"
# REGISTRY = the central domain registry consumed by every check.
REGISTRY="${CICD_REGISTRY:-$REPO_ROOT/domains.yml}"
export CICD_ROOT REPO_ROOT REGISTRY

# Verbosity + dry-run are opt-in, honoured by every script.
: "${CICD_VERBOSE:=0}"
: "${CICD_DRY_RUN:=0}"

# --- Logging (all to stderr; stdout stays clean for machine-readable payloads) --
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log()  { printf '%s [INFO]  %s\n' "$(_ts)" "$*" >&2; }
warn() { printf '%s [WARN]  %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }
# vlog only emits when -v / CICD_VERBOSE=1 is set.
vlog() { [ "${CICD_VERBOSE:-0}" = "1" ] && printf '%s [DEBUG] %s\n' "$(_ts)" "$*" >&2; return 0; }

# die <msg> [exit-code] — log an error and exit. Default exit code 1.
die() { err "$1"; exit "${2:-1}"; }

# run <cmd...> — execute unless dry-run, in which case just echo the command.
run() {
  if [ "${CICD_DRY_RUN:-0}" = "1" ]; then
    printf '%s [DRYRUN] %s\n' "$(_ts)" "$*" >&2
    return 0
  fi
  vlog "exec: $*"
  "$@"
}

# --- Small helpers -----------------------------------------------------------
# have <cmd> — true if command is on PATH.
have() { command -v "$1" >/dev/null 2>&1; }
# require <cmd> — die if a needed tool is missing.
require() { have "$1" || die "required tool not found on PATH: $1" 3; }

# --- Registry reader ---------------------------------------------------------
# Flat schema: `domains:` at column 0, each domain key at 2 spaces, each scalar
# field at 4 spaces as `key: value`. Surrounding double-quotes are stripped, as
# are inline ` # comments` (outside quotes only) and trailing whitespace — a
# `status: active  # note` line must parse as exactly `active`, or checks.sh
# would treat the domain as not-active and skip the gate GREEN.

# registry_file — echo the resolved registry path (die if missing).
registry_file() {
  [ -f "$REGISTRY" ] || die "domain registry not found: $REGISTRY" 3
  printf '%s\n' "$REGISTRY"
}

# domains_list — print every domain key, one per line.
domains_list() {
  awk '
    /^domains:[[:space:]]*$/ { indomains = 1; next }
    indomains && /^[^[:space:]]/ { indomains = 0 }
    indomains && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      key = $1; sub(/:$/, "", key); print key
    }
  ' "$(registry_file)"
}

# domain_field <domain> <field> — print a scalar field for one domain ("" if unset).
domain_field() {
  local domain="$1" field="$2"
  awk -v want="$domain" -v field="$field" '
    /^domains:[[:space:]]*$/ { indomains = 1; next }
    indomains && /^[^[:space:]]/ { indomains = 0 }
    indomains && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      cur = $1; sub(/:$/, "", cur); next
    }
    indomains && cur == want && /^    [A-Za-z0-9_-]+:/ {
      line = $0
      sub(/^    [A-Za-z0-9_-]+:[[:space:]]*/, "", line)
      key = $1; sub(/:$/, "", key)
      if (key == field) {
        # Strip the inline comment + trailing whitespace BEFORE unquoting, so
        # `active  # note` and `"cicd .github" ` both yield their bare values.
        # A quoted value is cut at its closing quote (a # inside the quotes is
        # part of the value); a bare value drops ` #...` (whitespace-preceded,
        # per YAML — a mid-token # like origin/ma#in is kept).
        if (line ~ /^"/ && match(line, /^"[^"]*"/)) {
          line = substr(line, RSTART, RLENGTH)
        } else {
          sub(/(^|[[:space:]])#.*$/, "", line)
        }
        sub(/[[:space:]]+$/, "", line)
        gsub(/^"|"$/, "", line)
        print line
        exit
      }
    }
  ' "$(registry_file)"
}

# domain_exists <domain> — return 0 if the domain is present in the registry.
domain_exists() {
  local d="$1" x
  while IFS= read -r x; do
    [ "$x" = "$d" ] && return 0
  done < <(domains_list)
  return 1
}
