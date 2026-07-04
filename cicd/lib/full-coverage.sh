#!/usr/bin/env bash
# full-coverage.sh — Fleet V3
# PURPOSE: CICD v2 step 3 (C178289477824693). Fails if the TOTAL line coverage of
# the product code in a Coverlet/dotnet-coverage Cobertura report is below the
# domain's floor. Complements diff-coverage.sh (which gates only changed lines):
# the floor stops whole-codebase coverage from regressing and is ratcheted upward
# as the test estate grows toward full coverage. Deterministic, no AI.
#
# Usage: full-coverage.sh --cobertura <path> --min <pct 0-100> [--top <n>] [--dry-run] [-v] [-h]
set -euo pipefail

MIN=0
COBERTURA=""
TOP=20
DRY_RUN=0
VERBOSE=0

usage() { grep '^# Usage' "$0" | sed 's/^# //'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cobertura) COBERTURA="$2"; shift 2 ;;
    --min) MIN="$2"; shift 2 ;;
    --top) TOP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$COBERTURA" ] || { echo "--cobertura required" >&2; exit 1; }
[ -f "$COBERTURA" ] || { echo "cobertura file not found: $COBERTURA" >&2; exit 1; }

python3 - "$COBERTURA" "$MIN" "$TOP" "$VERBOSE" "$DRY_RUN" <<'PY'
import sys, re
import xml.etree.ElementTree as ET

cobertura, min_pct, top, verbose, dry_run = (
    sys.argv[1], float(sys.argv[2]), int(sys.argv[3]),
    sys.argv[4] == "1", sys.argv[5] == "1")

# Files that carry no unit-coverage burden — the SAME exclusion set as
# diff-coverage.sh, so the two gates agree on what "product code" means:
#   * test-project files (belt-and-braces; reports normally exclude them already),
#   * app entry points Program.cs/Startup.cs (composition roots, no unit seam),
#   * generated EF artifacts (Migrations/, *.Designer.cs, *ModelSnapshot.cs, *.g.cs).
_TEST_PATH = re.compile(r"(^|/)([^/]*\.(Tests?|IntegrationTests|NUnit\.Tests|Playwright)|Tests?)/")
_ENTRYPOINT = re.compile(r"(^|/)(Program|Startup)\.cs$")
_GENERATED = re.compile(r"(^|/)Migrations/|\.Designer\.cs$|ModelSnapshot\.cs$|\.g\.cs$")

def excluded(path):
    return bool(_TEST_PATH.search(path) or _ENTRYPOINT.search(path) or _GENERATED.search(path))

tree = ET.parse(cobertura)
hit_by_file = {}  # filename -> {line: hits}
# A single source file can appear as MANY <class> entries (C# partial classes,
# nested types, async state machines). MERGE their line hits taking the max, or a
# method covered in an early entry vanishes (lodgers #294: DbSeeder.cs, 43 entries).
for cls in tree.getroot().iter("class"):
    fname = cls.get("filename", "")
    if excluded(fname):
        continue
    dest = hit_by_file.setdefault(fname, {})
    for l in cls.iter("line"):
        n = int(l.get("number"))
        dest[n] = max(dest.get(n, 0), int(l.get("hits", "0")))

total = sum(len(lines) for lines in hit_by_file.values())
covered = sum(1 for lines in hit_by_file.values() for h in lines.values() if h > 0)

# Zero coverable lines = the collector instrumented nothing. That is an
# infrastructure failure, not 100% coverage — fail loudly, never vacuously pass.
if total == 0:
    print("::error::full-coverage: report contains no coverable product lines — instrumentation collected nothing")
    sys.exit(0 if dry_run else 1)

pct = covered / total * 100
print(f"full-coverage: {covered}/{total} lines covered ({pct:.1f}%) across {len(hit_by_file)} files")

if verbose:
    # Worst offenders first — the work list for closing the gap to full coverage.
    gaps = sorted(
        ((sum(1 for h in ls.values() if h == 0), len(ls), f) for f, ls in hit_by_file.items()),
        reverse=True)
    shown = [g for g in gaps if g[0] > 0][:top]
    if shown:
        print(f"  top {len(shown)} files by uncovered lines:")
        for miss, n, f in shown:
            print(f"    {miss:5d}/{n:<5d} uncovered  {(n - miss) / n * 100:5.1f}%  {f}")

if pct < min_pct:
    print(f"::error::full-coverage {pct:.1f}% below the domain floor {min_pct}%")
    sys.exit(0 if dry_run else 1)
print(f"full-coverage {pct:.1f}% >= {min_pct}% — pass")
PY
