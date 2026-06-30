#!/usr/bin/env bash
# ci/lib.sh — shared helpers for the kukuln CICD spine (sourced by every ci/*.sh).
#
# SPINE PRINCIPLE (SPEC §2): canonical logic = these versioned .sh scripts. They run
# IDENTICALLY locally (DRY_RUN=1, for proofs on the dev workbench) or in CI (on the
# self-hosted GitHub Actions runner). The workflow YAML is a thin caller: it provides the
# runner, the workflow_dispatch trigger and the secrets plumbing, and holds NO decision logic.
set -euo pipefail

# Resolve repo layout from this file: .github/scripts/ci/lib.sh -> repo root.
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$CI_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
export CI_DIR SCRIPTS_DIR REPO_ROOT
DRY_RUN="${DRY_RUN:-0}"

log()   { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
note()  { printf '::notice::%s\n' "$*"; }
warn()  { printf '::warning::%s\n' "$*" >&2; }
err()   { printf '::error::%s\n' "$*" >&2; }
die()   { err "$*"; exit "${2:-1}"; }
stage() { printf '\n========== %s ==========\n' "$*"; }

# Write KEY=VAL to $GITHUB_ENV when in CI; always echo so a local run can read it too.
set_out() {
  local k="$1" v="$2"
  [ -n "${GITHUB_ENV:-}" ] && printf '%s=%s\n' "$k" "$v" >> "$GITHUB_ENV"
  printf 'set %s=%s\n' "$k" "$v"
}

# Side-effects that touch the outside world (git push/tag, gh pr create, the live TOTP gate)
# are DESCRIBED, not executed, under DRY_RUN — so a local proof never mutates a remote or
# pages Crom. In CI (DRY_RUN=0) they run for real.
run_or_echo() {
  if [ "$DRY_RUN" = "1" ]; then printf 'DRY-RUN would: %s\n' "$*"; return 0; fi
  # Callers pass a single command STRING (may carry && / redirects); eval-as-string is intended.
  # shellcheck disable=SC2294
  eval "$@"
}
