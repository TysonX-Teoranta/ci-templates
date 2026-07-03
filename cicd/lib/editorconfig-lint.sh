#!/usr/bin/env bash
# editorconfig-lint.sh — custom zero-tolerance check for a repo's root .editorconfig:
# (1) every non-blank/non-comment line is a valid `[section]` header or `key = value`
# pair, (2) no key is duplicated within the same section, (3) no trailing whitespace,
# (4) exactly one trailing newline. No INI/editorconfig library dependency (pure
# awk), and deliberately not a reformatter — spacing/quoting style is left alone,
# only unambiguous structural defects gate.
#
# Args: [--report-append <txt>] <file> [file ...]
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

  issues="$(awk '
    BEGIN { section = "<global>" }
    {
      line = $0
      sub(/\r$/, "", line)
      trimmed = line
      sub(/^[ \t]+/, "", trimmed); sub(/[ \t]+$/, "", trimmed)
      if (trimmed == "" || trimmed ~ /^[#;]/) next
      if (trimmed ~ /^\[.+\]$/) { section = trimmed; next }
      if (trimmed ~ /^[A-Za-z0-9_.-]+[ \t]*=/) {
        key = trimmed; sub(/[ \t]*=.*/, "", key)
        k = section SUBSEP tolower(key)
        if (seen[k]++) print "duplicate key \x27" key "\x27 in section " section
        next
      }
      print "malformed line: " trimmed
    }
  ' "$f")"

  bad=0
  if [ -n "$issues" ]; then
    bad=1
    while IFS= read -r msg; do emit "$f" EDITORCONFIG_STRUCTURE "$msg"; done <<< "$issues"
  fi
  if grep -qP '[ \t]+$' "$f"; then
    bad=1
    emit "$f" EDITORCONFIG_WHITESPACE "trailing whitespace"
  fi
  if [ -n "$(tail -c1 "$f" 2>/dev/null)" ]; then
    bad=1
    emit "$f" EDITORCONFIG_WHITESPACE "missing final newline"
  fi
  [ "$bad" = "1" ] && fails=$((fails + 1))
done

printf '%s\n' "$fails"
exit 0
