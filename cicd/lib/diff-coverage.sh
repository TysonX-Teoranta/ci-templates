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

# Walk the unified diff and collect ADDED lines that are executable-CODE-shaped.
# Non-executable added lines (comments, blank lines, lone braces, using/namespace)
# can never be covered by a test, so they must not demand coverage — otherwise a
# comment-only or doc-only change (exactly what the comment-density check asks for)
# scores 0% and fails. This is content-based, so it holds even when the changed
# file is entirely absent from the coverage report (e.g. never loaded by any test).
def is_code_line(txt):
    s = txt.strip()
    if not s:
        return False                       # blank
    if s.startswith(("//", "/*", "*", "///")):
        return False                       # line/block/doc comment
    if s in ("{", "}", "(", ")", "};", ");", "})", "],", "],["):
        return False                       # structural brace/paren only
    if s.startswith(("using ", "namespace ")) and s.endswith((";", "{")):
        return False                       # import / namespace declaration
    return True

# Files that carry no unit-coverage burden and must not gate diff-coverage:
#   * Test-project files (*.Tests/.NUnit.Tests/.IntegrationTests/.Playwright, plain
#     Tests/) — the tests themselves, excluded from the coverage report
#     (coverage.runsettings IncludeTestAssembly=false); counting them scores 0%.
#   * The app entry point Program.cs / Startup.cs — top-level composition-root
#     statements that boot the host and CANNOT be unit-tested (no seam to invoke
#     them without standing up the whole app); they are exercised by integration/
#     e2e runs, not unit coverage. A CLI-verb dispatch there would otherwise be
#     permanently uncoverable and block any entry-point change.
#   * Generated EF Core artifacts — Migrations/ folders (scaffolded DDL that is
#     exercised by replaying the migration chain against a database, never by
#     unit tests), plus *.Designer.cs / *ModelSnapshot.cs / *.g.cs. Mirrors the
#     analyzer gate's generated-code exclusion (parse-diagnostics.sh); without
#     this, any migration hotfix scores 0% and is permanently unmergeable.
_TEST_PATH = re.compile(r"(^|/)([^/]*\.(Tests?|IntegrationTests|NUnit\.Tests|Playwright)|Tests?)/")
_ENTRYPOINT = re.compile(r"(^|/)(Program|Startup)\.cs$")
_GENERATED = re.compile(r"(^|/)Migrations/|\.Designer\.cs$|ModelSnapshot\.cs$|\.g\.cs$")

def excluded(path):
    return bool(_TEST_PATH.search(path) or _ENTRYPOINT.search(path) or _GENERATED.search(path))

changed = {}                               # file -> set(code line numbers)
cur_file = None
new_ln = 0
for line in diff.splitlines():
    if line.startswith("+++ b/"):
        path = line[6:]
        cur_file = None if excluded(path) else path
        if cur_file is not None:
            changed.setdefault(cur_file, set())
        continue
    m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
    if m:
        new_ln = int(m.group(1))
        continue
    if cur_file is None:
        continue
    if line.startswith("+"):               # added line on the new side
        if is_code_line(line[1:]):
            changed[cur_file].add(new_ln)
        new_ln += 1
    elif line.startswith("-"):             # removed line — no new-side number
        pass
    else:                                  # context line advances the new side
        new_ln += 1

if not any(changed.values()):
    print("diff-coverage: no changed executable .cs lines — pass")
    sys.exit(0)

tree = ET.parse(cobertura)
hit_by_file = {}  # path suffix match -> {line: hits}
# A single source file can appear as MANY <class> entries (C# partial classes,
# nested types, async state machines each get their own <class filename="X.cs">).
# MERGE their line hits — taking the max — rather than letting the last entry
# overwrite the earlier ones, or a covered method in an early entry vanishes and
# reads as "no cobertura entry" (lodgers #294: DbSeeder.cs has 43 class entries).
for cls in tree.getroot().iter("class"):
    fname = cls.get("filename", "")
    dest = hit_by_file.setdefault(fname, {})
    for l in cls.iter("line"):
        n = int(l.get("number"))
        dest[n] = max(dest.get(n, 0), int(l.get("hits", "0")))

def find_hits(path):
    # Suffix matching lines up absolute cobertura filenames with repo-relative
    # diff paths, but it must align on a `/` boundary — a bare endswith would
    # bind LodgersSite/Foo.cs to LodgersSite.Client/Foo.cs coverage. Exact match
    # wins outright; otherwise take the LONGEST boundary-aligned suffix match
    # rather than whichever entry the dict yields first.
    best, best_len = None, -1
    for fname, lines in hit_by_file.items():
        if fname == path:
            return lines
        if fname.endswith("/" + path) or path.endswith("/" + fname):
            n = min(len(fname), len(path))
            if n > best_len:
                best, best_len = lines, n
    return best

# Every remaining changed line is executable code. Covered = cobertura reports a
# hit>0 for it. Two distinct "not covered" cases:
#   * File ABSENT from the report (never loaded by any test): every changed line
#     counts UNCOVERED — a new untested file must not pass vacuously.
#   * File PRESENT but the line has NO entry: the instrumenter itself declares the
#     line non-executable — method/ctor declaration headers and their parameter
#     continuation lines carry no sequence points, so NO test can ever hit them.
#     Demanding them made any PR that adds or renames a method permanently
#     unmergeable at min=100 (lodgers #300: five signature lines of fully-tested
#     methods were the only misses). Excluded, same class as comments/braces.
#     Untested method BODIES are unaffected: their lines appear as 0-hit entries
#     and are still demanded.
total, covered, unmatched = 0, 0, []
for path, lns in changed.items():
    hits = find_hits(path)
    for ln in lns:
        if hits and ln not in hits:
            continue                       # instrumented file, non-executable line
        total += 1
        if hits is not None and hits.get(ln, 0) > 0:
            covered += 1
        else:
            unmatched.append(f"{path}:{ln}")

pct = (covered / total * 100) if total else 100.0
if verbose:
    print(f"diff-coverage: {covered}/{total} changed lines covered ({pct:.1f}%)")
    if unmatched:
        print(f"  {len(unmatched)} changed lines uncovered (0 hits, or file never loaded by any test)")

if pct < min_pct:
    print(f"::error::diff-coverage {pct:.1f}% below minimum {min_pct}%")
    sys.exit(0 if dry_run else 1)
print(f"diff-coverage {pct:.1f}% >= {min_pct}% — pass")
PY
