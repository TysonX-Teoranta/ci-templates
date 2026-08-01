#!/usr/bin/env bash
# exclude-justify-lint.sh — custom zero-tolerance check enforcing the coverage
# doctrine (Crom 2026-07-26): the 100% target is "100% OR
# [ExcludeFromCodeCoverage]-with-justification". So every ExcludeFromCodeCoverage
# usage in product .cs MUST carry a non-empty Justification = "..." — otherwise a
# bare attribute becomes a silent hole that drops a line/branch out of the
# denominator with no recorded reason. This makes the exclusion escape-hatch
# auditable and keeps the "tiny unreachable remainder" honest.
#
# Deterministic, no dotnet/analyzer dependency — just python3 text analysis.
#
# Passes:  [ExcludeFromCodeCoverage(Justification = "reason")]
#          [ExcludeFromCodeCoverageAttribute(Justification="reason")]
# Fails:   [ExcludeFromCodeCoverage]            (no args)
#          [ExcludeFromCodeCoverage()]          (empty args)
#          [ExcludeFromCodeCoverage(Justification = "")]  (blank reason)
#
# Args: [--report-append <txt>] <file.cs> [file.cs ...]
# Output: prints the NUMBER OF FAILING OCCURRENCES to stdout (machine-readable),
# detail to stderr / the appended report. Exit 0 always (the caller decides the
# verdict). Exit 3 = required tool missing.

set -uo pipefail

command -v python3 >/dev/null 2>&1 || exit 3

REPORT=""
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --report-append) REPORT="${2:-}"; shift 2 ;;
    *)               FILES+=("$1"); shift ;;
  esac
done

[ "${#FILES[@]}" -eq 0 ] && { echo 0; exit 0; }

python3 - "$REPORT" "${FILES[@]}" <<'PY'
import re, sys

report = sys.argv[1]
files = sys.argv[2:]

# Match the attribute head, optional "Attribute" suffix, optional (...) arg list.
# The arg body is a sequence of non-paren/non-quote chars or complete string
# literals (regular, escaped, or @-verbatim), so a ')' INSIDE a quoted
# Justification no longer truncates the capture (the old non-greedy .*? stopped
# at the first close paren and mangled any reason text containing brackets).
_ATTR = re.compile(
    r'ExcludeFromCodeCoverage(?:Attribute)?\s*'
    r'(\(((?:[^()"]|"(?:[^"\\]|\\.)*"|@"(?:[^"]|"")*")*)\))?', re.S)
# A valid justification = Justification = "<non-empty>". Allow @"..." verbatim too.
_JUST = re.compile(r'Justification\s*=\s*@?"([^"]*)"', re.S)

lines = []
fails = 0
for path in files:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        continue
    for m in _ATTR.finditer(text):
        args = m.group(2)  # inside the parens, or None when no ()
        jm = _JUST.search(args) if args else None
        if jm and jm.group(1).strip():
            continue  # justified — ok
        line_no = text.count("\n", 0, m.start()) + 1
        fails += 1
        rel = path
        lines.append(f'error\texclude-justify\t{rel}\t{line_no}:1\t'
                     f'[ExcludeFromCodeCoverage] without a non-empty Justification = "..." '
                     f'(coverage doctrine: exclusions must be justified)')

for ln in lines:
    sys.stderr.write(ln + "\n")
if report and lines:
    with open(report, "a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

print(fails)
PY
