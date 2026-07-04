#!/usr/bin/env bash
# diff-coverage.sh — Fleet V3
# PURPOSE: CICD v2 step 3 (C178289477824693). Fails if lines touched by this PR's
# diff have < threshold% Coverlet (Cobertura XML) test coverage. Gates only changed
# lines — small changes carry a small test burden, never zero. Deterministic, no AI.
#
# Usage: diff-coverage.sh --cobertura <path> --min <pct 0-100> [--base <ref>] [--dry-run] [-v] [-h]
set -euo pipefail

MIN=80
BASE="origin/main"
COBERTURA=""
DRY_RUN=0
VERBOSE=0

usage() { grep '^# Usage' "$0" | sed 's/^# //'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cobertura) COBERTURA="$2"; shift 2 ;;
    --min) MIN="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$COBERTURA" ] || { echo "--cobertura required" >&2; exit 1; }
[ -f "$COBERTURA" ] || { echo "cobertura file not found: $COBERTURA" >&2; exit 1; }

python3 - "$COBERTURA" "$MIN" "$VERBOSE" "$BASE" "$DRY_RUN" <<'PY'
import subprocess, sys, re
import xml.etree.ElementTree as ET

cobertura, min_pct, verbose, base, dry_run = sys.argv[1], float(sys.argv[2]), sys.argv[3] == "1", sys.argv[4], sys.argv[5] == "1"

# changed line numbers per file, from unified diff hunk headers (@@ -a,b +c,d @@)
diff = subprocess.run(
    ["git", "diff", "--diff-filter=ACMR", "--unified=0", f"{base}...HEAD", "--", "*.cs"],
    capture_output=True, text=True, check=True
).stdout

changed = {}
cur_file = None
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        cur_file = line[6:]
        changed.setdefault(cur_file, set())
    m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
    if m and cur_file:
        start = int(m.group(1))
        count = int(m.group(2)) if m.group(2) else 1
        # A deletion-only hunk shows "+<line>,0" — zero lines exist on the new side,
        # so there is nothing to demand coverage of. Counting max(count,1) here would
        # gate one untouched line per deletion hunk.
        for ln in range(start, start + count):
            changed[cur_file].add(ln)

if not any(changed.values()):
    print("diff-coverage: no changed .cs lines — pass")
    sys.exit(0)

tree = ET.parse(cobertura)
hit_by_file = {}  # path suffix match -> {line: hits}
for cls in tree.getroot().iter("class"):
    fname = cls.get("filename", "")
    lines = {int(l.get("number")): int(l.get("hits", "0")) for l in cls.iter("line")}
    hit_by_file[fname] = lines

def find_hits(path):
    for fname, lines in hit_by_file.items():
        if fname.endswith(path) or path.endswith(fname):
            return lines
    return None

total, covered, unmatched = 0, 0, []
for path, lns in changed.items():
    hits = find_hits(path)
    for ln in lns:
        if hits is None:
            # File absent from the coverage report entirely: a new/never-loaded file.
            # Stay strict — its changed lines all gate as uncovered (a new untested
            # file must not pass vacuously).
            total += 1
            unmatched.append(f"{path}:{ln}")
            continue
        if ln not in hits:
            # The file IS in the report but cobertura does not track this line:
            # comments, blank lines, braces, usings — nothing instrumentable.
            # Demanding coverage of non-executable lines would fail every
            # comment-only change (the exact work the comment-density check asks
            # for), so untracked lines carry no test burden.
            continue
        total += 1
        if hits[ln] > 0:
            covered += 1

pct = (covered / total * 100) if total else 100.0
if verbose:
    print(f"diff-coverage: {covered}/{total} changed lines covered ({pct:.1f}%)")
    if unmatched:
        print(f"  {len(unmatched)} changed lines had no cobertura entry (new/untested files)")

if pct < min_pct:
    print(f"::error::diff-coverage {pct:.1f}% below minimum {min_pct}%")
    sys.exit(0 if dry_run else 1)
print(f"diff-coverage {pct:.1f}% >= {min_pct}% — pass")
PY
