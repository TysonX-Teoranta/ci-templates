#!/usr/bin/env bash
# full-coverage.sh — Fleet V3 (coverage-expansion: branch + honest denominator + ratchet)
# PURPOSE: CICD v2 step 3 (C178289477824693). Fails if the TOTAL line coverage OR
# branch coverage of the product code in a Cobertura report is below the domain floor
# and/or below the committed high-water baseline (the ratchet). Complements
# diff-coverage.sh (which gates changed lines/branches). Deterministic, no AI.
#
# Usage: full-coverage.sh --cobertura <path> --min <linepct 0-100> [--min-branch <pct>]
#                         [--baseline <json>] [--bump-baseline] [--top <n>] [--dry-run] [-v] [-h]
#   --min-branch  floor for TOTAL branch coverage (default: 0 = report-only)
#   --baseline    ratchet file {"line":P,"branch":P}; measured may never drop below it
#   --bump-baseline  after a PASS, rewrite the baseline upward to the measured values
set -euo pipefail

MIN=0
MIN_BRANCH=0
COBERTURA=""
BASELINE=""
BUMP=0
TOP=20
DRY_RUN=0
VERBOSE=0

usage() { grep '^# Usage\|^#   --' "$0" | sed 's/^# //'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cobertura) COBERTURA="$2"; shift 2 ;;
    --min) MIN="$2"; shift 2 ;;
    --min-branch) MIN_BRANCH="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --bump-baseline) BUMP=1; shift ;;
    --top) TOP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$COBERTURA" ] || { echo "--cobertura required" >&2; exit 1; }
[ -f "$COBERTURA" ] || { echo "cobertura file not found: $COBERTURA" >&2; exit 1; }

python3 - "$COBERTURA" "$MIN" "$TOP" "$VERBOSE" "$DRY_RUN" "$MIN_BRANCH" "$BASELINE" "$BUMP" <<'PY'
import sys, re, json, os
import xml.etree.ElementTree as ET

cobertura, min_pct, top, verbose, dry_run, min_branch, baseline_path, bump = (
    sys.argv[1], float(sys.argv[2]), int(sys.argv[3]),
    sys.argv[4] == "1", sys.argv[5] == "1", float(sys.argv[6]),
    sys.argv[7], sys.argv[8] == "1")

# Files that carry no unit-coverage burden — the SAME exclusion set as
# diff-coverage.sh, so the two gates agree on what "product code" means:
#   * test-project files (belt-and-braces; reports normally exclude them already),
#   * app entry points Program.cs/Startup.cs (composition roots, no unit seam),
#   * generated EF artifacts (Migrations/, *.Designer.cs, *ModelSnapshot.cs, *.g.cs),
#   * CI tooling under .github/ (gate scripts, never loaded by the app test host),
#   * SeedData/ (hand-written static seed rows — data, not behaviour),
#   * *.razor / *.cshtml (UI markup; the UI is gated by the Playwright walk suite,
#     not unit coverage, so markup would sit permanently at 0% and crush the %).
_TEST_PATH = re.compile(r"(^|/)([^/]*\.(Tests?|IntegrationTests|NUnit\.Tests|Playwright)|Tests?)/")
_ENTRYPOINT = re.compile(r"(^|/)(Program|Startup)\.cs$")
_GENERATED = re.compile(r"(^|/)Migrations/|\.Designer\.cs$|ModelSnapshot\.cs$|\.g\.cs$")
_CI_TOOLING = re.compile(r"^\.github/")
_SEED = re.compile(r"(^|/)SeedData/")
_MARKUP = re.compile(r"\.(razor|cshtml)$")

def excluded(path):
    return bool(_TEST_PATH.search(path) or _ENTRYPOINT.search(path)
                or _GENERATED.search(path) or _CI_TOOLING.search(path)
                or _SEED.search(path) or _MARKUP.search(path))

_COND = re.compile(r"\((\d+)/(\d+)\)")  # condition-coverage="50% (1/2)"
_PCT = re.compile(r"([\d.]+)")

def _branch_cov(line_el):
    # Branch coverage of one <line branch="true">, tolerant of BOTH cobertura
    # dialects the fleet sees: (a) a condition-coverage="P% (a/b)" attribute
    # (dotnet-coverage / older coverlet), or (b) coverlet's child elements
    # <conditions><condition coverage="P%"/></conditions> (one branch per
    # <condition>; covered = coverage > 0). Returns (covered, total) or None.
    m = _COND.search(line_el.get("condition-coverage", ""))
    if m:
        return int(m.group(1)), int(m.group(2))
    conds = line_el.findall("./conditions/condition")
    if conds:
        cov = 0
        for c in conds:
            pm = _PCT.search(c.get("coverage", "0"))
            if pm and float(pm.group(1)) > 0:
                cov += 1
        return cov, len(conds)
    return None

tree = ET.parse(cobertura)
hit_by_file = {}   # filename -> {line: hits}
br_by_file = {}    # filename -> {line: (cov, tot)}  branch conditions per line
# A single source file can appear as MANY <class> entries (C# partial classes,
# nested types, async state machines). MERGE their line hits taking the max, or a
# method covered in an early entry vanishes (lodgers #294: DbSeeder.cs, 43 entries).
for cls in tree.getroot().iter("class"):
    fname = cls.get("filename", "")
    if excluded(fname):
        continue
    dest = hit_by_file.setdefault(fname, {})
    bdest = br_by_file.setdefault(fname, {})
    for l in cls.iter("line"):
        n = int(l.get("number"))
        dest[n] = max(dest.get(n, 0), int(l.get("hits", "0")))
        if l.get("branch", "false").strip().lower() == "true":  # coverlet emits "True"
            ct = _branch_cov(l)
            if ct is not None:
                cov, tot = ct
                pc, pt = bdest.get(n, (0, 0))
                # keep the best-covered observation of this branch line
                if cov >= pc or pt == 0:
                    bdest[n] = (cov, tot)

total = sum(len(lines) for lines in hit_by_file.values())
covered = sum(1 for lines in hit_by_file.values() for h in lines.values() if h > 0)
br_tot = sum(t for f in br_by_file.values() for (_, t) in f.values())
br_cov = sum(c for f in br_by_file.values() for (c, _) in f.values())

# Zero coverable lines = the collector instrumented nothing. That is an
# infrastructure failure, not 100% coverage — fail loudly, never vacuously pass.
if total == 0:
    print("::error::full-coverage: report contains no coverable product lines — instrumentation collected nothing")
    sys.exit(0 if dry_run else 1)

pct = covered / total * 100
bpct = (br_cov / br_tot * 100) if br_tot else 100.0
print(f"full-coverage: {covered}/{total} lines ({pct:.1f}%), {br_cov}/{br_tot} branches ({bpct:.1f}%) across {len(hit_by_file)} files")

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

fail = False

# Absolute floors (belt).
if pct < min_pct:
    print(f"::error::full-coverage line {pct:.1f}% below the domain floor {min_pct}%")
    fail = True
if bpct < min_branch:
    print(f"::error::full-coverage branch {bpct:.1f}% below the domain branch floor {min_branch}%")
    fail = True

# Ratchet: measured may never drop below the committed high-water baseline.
if baseline_path:
    base = {"line": 0.0, "branch": 0.0}
    if os.path.exists(baseline_path):
        try:
            with open(baseline_path) as fh:
                base.update(json.load(fh))
        except (OSError, ValueError) as e:
            print(f"::error::full-coverage: baseline {baseline_path} unreadable ({e})")
            sys.exit(0 if dry_run else 1)
    tol = 0.05  # float-noise guard
    if pct + tol < float(base["line"]):
        print(f"::error::full-coverage line {pct:.1f}% regressed below baseline {base['line']}%")
        fail = True
    if bpct + tol < float(base["branch"]):
        print(f"::error::full-coverage branch {bpct:.1f}% regressed below baseline {base['branch']}%")
        fail = True
    if bump and not fail:
        # Never ratchet the branch baseline off a report that carried NO branch
        # data (br_tot == 0). dotnet-coverage's cobertura export emits no
        # conditions, so bpct is a vacuous 100% — locking it as the high-water
        # would break the gate the moment real branch data ever lands (real
        # branch < 100 would read as a regression). Line data is real, so line
        # always ratchets; branch ratchets only when it was actually measured.
        new = {"line": round(max(pct, float(base["line"])), 2),
               "branch": (round(max(bpct, float(base["branch"])), 2)
                          if br_tot else round(float(base["branch"]), 2))}
        with open(baseline_path, "w") as fh:
            json.dump(new, fh, indent=2)
            fh.write("\n")
        print(f"full-coverage: baseline ratcheted to line {new['line']}% branch {new['branch']}%")

if fail:
    sys.exit(0 if dry_run else 1)
print(f"full-coverage line {pct:.1f}% >= {min_pct}%, branch {bpct:.1f}% >= {min_branch}% — pass")
PY
