#!/usr/bin/env bash
# json-lint.sh — custom zero-tolerance check: every in-scope .json file must be
# (1) syntactically valid JSON and (2) formatted to a canonical indent (default 2
# spaces, jq's own re-serialization — no key reordering, so it never fights a repo's
# existing key order, only whitespace/indent drift).
#
# Deterministic, no dotnet/analyzer dependency — just jq. A file with invalid JSON
# always fails (and skips the formatting check, since there is no canonical form of
# broken JSON). A syntactically valid file that doesn't match its own canonical
# re-serialization fails formatting.
#
# Args: [--report-append <txt>] [--indent N] <file.json> [file.json ...]
# Output: prints the NUMBER OF FAILING FILES to stdout (machine-readable), detail to
# stderr / the appended report. Exit 0 always (the caller decides the verdict).

set -uo pipefail

INDENT="${CICD_JSON_INDENT:-2}"
REPORT=""
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --report-append) REPORT="${2:-}"; shift 2 ;;
    --indent)        INDENT="${2:-}"; shift 2 ;;
    *)               FILES+=("$1"); shift ;;
  esac
done

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

  err="$(jq empty "$f" 2>&1 1>/dev/null)"
  if [ -n "$err" ]; then
    fails=$((fails + 1))
    emit "$f" JSON_INVALID "not valid JSON: ${err//$'\n'/ }"
    continue
  fi

  canon="$(jq --indent "$INDENT" . "$f" 2>/dev/null)"
  actual="$(cat "$f")"
  if [ "$canon" != "$actual" ]; then
    fails=$((fails + 1))
    emit "$f" JSON_FORMAT "not canonically formatted (expected jq --indent ${INDENT} .)"
  fi
done

printf '%s\n' "$fails"
exit 0
