#!/usr/bin/env bash
# shell-lint.sh — custom zero-tolerance check: every in-scope .sh file must pass
# `shellcheck` clean (no warnings/errors at default severity).
#
# Thin wrapper, not a reimplementation — shellcheck IS the canonical tool (same one
# this repo's own scripts are held to). No reformatting attempted; shellcheck finds
# defects, it doesn't fix style.
#
# Args: [--report-append <txt>] <file.sh> [file.sh ...]
# Output: prints the NUMBER OF FAILING FILES to stdout (machine-readable), detail to
# stderr / the appended report. Exit 0 always (the caller decides the verdict).

set -uo pipefail

REPORT=""
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --report-append) REPORT="${2:-}"; shift 2 ;;
    *)               FILES+=("$1"); shift ;;
  esac
done

command -v shellcheck >/dev/null 2>&1 || { echo "shell-lint.sh: shellcheck not found on PATH" >&2; exit 3; }

emit() {
  # emit <file> <rule> <msg>
  local rel line
  rel=${1#"$(git -C "$(dirname "$1")" rev-parse --show-toplevel 2>/dev/null)"/}
  line="error\t${2}\t${rel:-$1}\t1:1\t${3}"
  printf '%b\n' "$line" >&2
  [ -n "$REPORT" ] && printf '%b\n' "$line" >> "$REPORT"
}

fails=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue

  if ! shellcheck "$f" >/dev/null 2>&1; then
    fails=$((fails + 1))
    detail="$(shellcheck -f gcc "$f" 2>/dev/null | tr '\n' ' ')"
    emit "$f" SHELLCHECK "${detail:-shellcheck reported findings}"
  fi
done

printf '%s\n' "$fails"
exit 0
