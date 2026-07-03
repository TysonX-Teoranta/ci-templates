#!/usr/bin/env bash
# xml-lint.sh — custom zero-tolerance check: every in-scope XML-family file
# (.xml/.csproj/.props/.targets) must be (1) well-formed XML and (2) free of
# trailing whitespace / missing-final-newline.
#
# Deliberately NOT a full canonical-reformat gate like json-lint.sh: real .csproj
# files here use tabs, a UTF-8 BOM, heavy commenting and MSBuild Condition
# attributes with embedded regex — a naive parse+re-serialize round-trip (e.g.
# Python's xml.dom.minidom) reliably mangles all of that (drops the BOM, rewrites
# indentation, and is well known to inject spurious blank lines). Shipping that as
# a hard gate would false-fail real, correct files. Validity + whitespace hygiene
# are the safe, unambiguous subset; full XML pretty-printing is not attempted.
#
# Args: [--report-append <txt>] <file.xml> [file.xml ...]
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

command -v python3 >/dev/null 2>&1 || { echo "xml-lint.sh: python3 not found on PATH" >&2; exit 3; }

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

  err="$(python3 -c '
import sys, xml.dom.minidom
try:
    xml.dom.minidom.parse(sys.argv[1])
except Exception as e:
    print(e)
    sys.exit(1)
' "$f" 2>&1)"
  if [ -n "$err" ]; then
    fails=$((fails + 1))
    emit "$f" XML_INVALID "not well-formed XML: ${err//$'\n'/ }"
    continue
  fi

  bad=0
  grep -qP '[ \t]+$' "$f" && bad=1
  [ -n "$(tail -c1 "$f" 2>/dev/null)" ] && bad=1   # missing trailing newline
  if [ "$bad" = "1" ]; then
    fails=$((fails + 1))
    emit "$f" XML_WHITESPACE "trailing whitespace and/or missing final newline"
  fi
done

printf '%s\n' "$fails"
exit 0
