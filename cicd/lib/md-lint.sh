#!/usr/bin/env bash
# md-lint.sh — custom zero-tolerance check for in-scope .md files: (1) every fenced
# code block (```) is closed, (2) no trailing whitespace, (3) exactly one trailing
# newline. Deliberately not a full markdown-style linter (heading levels, line
# length etc. are subjective house-style, not defects) — an unclosed code fence is
# the one Markdown defect that's unambiguous and actually breaks rendering.
#
# Args: [--report-append <txt>] <file.md> [file.md ...]
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

  fence_count=$(grep -cE '^[[:space:]]*(```|~~~)' "$f")
  bad=0
  if [ $((fence_count % 2)) -ne 0 ]; then
    bad=1
    emit "$f" MD_UNCLOSED_FENCE "odd number of fenced-code-block markers ($fence_count) — a code fence is unclosed"
  fi
  if grep -qP '[ \t]+$' "$f"; then
    bad=1
    emit "$f" MD_WHITESPACE "trailing whitespace"
  fi
  if [ -n "$(tail -c1 "$f" 2>/dev/null)" ]; then
    bad=1
    emit "$f" MD_WHITESPACE "missing final newline"
  fi
  [ "$bad" = "1" ] && fails=$((fails + 1))
done

printf '%s\n' "$fails"
exit 0
