#!/usr/bin/env bash
# diff-coverage.sh — Fleet V3 (coverage-expansion: branch on changed lines + exclusions)
# PURPOSE: CICD v2 step 3 (C178289477824693). Fails if lines touched by this PR's
# diff have < threshold% line coverage OR, for changed branch lines, < threshold%
# branch coverage. Gates only changed lines — small changes carry a small test
# burden, never zero. Deterministic, no AI.
#
# Usage: diff-coverage.sh --cobertura <path> --min <pct 0-100> [--min-branch <pct>]
#                         [--base <ref>] [--dry-run] [-v] [-h]
#   --min-branch  floor for branch coverage of CHANGED branch lines (default: same as --min)
set -euo pipefail

MIN=80
MIN_BRANCH=""
BASE="origin/main"
COBERTURA=""
DRY_RUN=0
VERBOSE=0

usage() { grep '^# Usage\|^#   --' "$0" | sed 's/^# //'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cobertura) COBERTURA="$2"; shift 2 ;;
    --min) MIN="$2"; shift 2 ;;
    --min-branch) MIN_BRANCH="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$COBERTURA" ] || { echo "--cobertura required" >&2; exit 1; }
[ -f "$COBERTURA" ] || { echo "cobertura file not found: $COBERTURA" >&2; exit 1; }
[ -n "$MIN_BRANCH" ] || MIN_BRANCH="$MIN"

python3 - "$COBERTURA" "$MIN" "$VERBOSE" "$BASE" "$DRY_RUN" "$MIN_BRANCH" <<'PY'
import subprocess, sys, re
import xml.etree.ElementTree as ET

cobertura, min_pct, verbose, base, dry_run, min_branch = (
    sys.argv[1], float(sys.argv[2]), sys.argv[3] == "1", sys.argv[4],
    sys.argv[5] == "1", float(sys.argv[6]))

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
#   * CI tooling under .github/ — gate scripts and file-based tool programs
#     (e.g. ci/il-type-scan.cs) run by the CICD spine itself, never loaded by
#     the app's test host; counting them scores 0% and blocks any gate change.
#   * SeedData/ — hand-written static seed rows (DbSeeder.*), data not behaviour.
#   * *.razor / *.cshtml — UI markup gated by Playwright walks, not unit coverage.
#     (Kept in lockstep with full-coverage.sh so both gates agree on product code.)
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

_COND = re.compile(r"\((\d+)/(\d+)\)")  # condition-coverage="50% (1/2)"
_PCT = re.compile(r"([\d.]+)")

def _branch_cov(line_el):
    # Branch coverage of one <line branch="true">, tolerant of BOTH cobertura
    # dialects: (a) condition-coverage="P% (a/b)" attribute, or (b) coverlet's
    # <conditions><condition coverage="P%"/></conditions> children (one branch
    # per <condition>; covered = coverage > 0). Returns (covered, total) or None.
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
hit_by_file = {}   # path suffix match -> {line: hits}
br_by_file = {}    # path suffix match -> {line: (cov, tot)}
# A single source file can appear as MANY <class> entries (C# partial classes,
# nested types, async state machines each get their own <class filename="X.cs">).
# MERGE their line hits — taking the max — rather than letting the last entry
# overwrite the earlier ones, or a covered method in an early entry vanishes and
# reads as "no cobertura entry" (lodgers #294: DbSeeder.cs has 43 class entries).
for cls in tree.getroot().iter("class"):
    fname = cls.get("filename", "")
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
                if cov >= pc or pt == 0:
                    bdest[n] = (cov, tot)

_TYPE_DECL = re.compile(r"\b(class|struct|record|enum|interface)\s+\w")
_LINE_COMMENT = re.compile(r"//[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_CONST_STMT = re.compile(r"(?:^|(?<=\n))\s*(?:(?:public|private|protected|internal|new)\s+)*const\s[^;]*;")

def declaration_only_file(path):
    # Enum- and interface-only files compile to ZERO sequence points — the
    # instrumenter can never list them, so under the never-loaded rule below any
    # changed enum member or interface signature is permanently uncoverable and
    # blocks the PR at min=100 (lodgers #367: a new enum member + two interface
    # method signatures were 3 of the 4 misses). Same class as declaration lines
    # (lodgers #300). Skip a never-loaded file ONLY when it declares at least one
    # type and every declared type is enum/interface; files with class/struct/
    # record types (or no type declaration at all, e.g. the selftest's top-level
    # statements) stay strict. Known narrow fail-open: an interface file whose
    # default method impls are untested skips too — accepted, StyleCop style here
    # bans default interface members.
    #
    # Consts-only class files (constants catalogs like Permissions.cs) are the
    # same class of file: const fields are inlined at compile time and carry NO
    # IL, so the file can never appear in a coverage report either (lodgers
    # #451: two new policy-name consts were the only misses at min=100). Skip
    # them ONLY when, after removing comments and const declarations, nothing
    # member-shaped remains — a method, property, or (static) readonly field
    # (those DO emit IL once loaded) keeps the file strict.
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
    except OSError:
        return False
    src = _BLOCK_COMMENT.sub("", _LINE_COMMENT.sub("", src))
    kinds = {m.group(1) for m in _TYPE_DECL.finditer(src)}
    if not kinds:
        return False
    if kinds <= {"enum", "interface"}:
        return True
    body = _CONST_STMT.sub("", src)
    for raw in body.splitlines():
        s = raw.strip()
        if not s or s in ("{", "}", "};"):
            continue                       # blank / structural brace
        if s.startswith(("using ", "namespace ", "[")):
            continue                       # import, namespace, attribute
        if _TYPE_DECL.search(s):
            continue                       # type declaration header
        return False                       # anything else is member-shaped
    return True

def exclusion_attributed_file(path):
    # A file whose types carry [ExcludeFromCodeCoverage] is absent from the report
    # BY SANCTIONED DESIGN (the S4 target is "100% or excluded-with-justification"),
    # not because it was never loaded — so its changed lines must not count as
    # uncovered (an exclusion-sweep PR otherwise reads 0% and can never merge).
    # The exclude-justify lint separately fails any such attribute lacking a
    # non-empty Justification, so this cannot become an unjustified escape hatch.
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return "ExcludeFromCodeCoverage" in fh.read()
    except OSError:
        return False

def find_hits(path):
    # Suffix matching lines up absolute cobertura filenames with repo-relative
    # diff paths, but it must align on a `/` boundary — a bare endswith would
    # bind LodgersSite/Foo.cs to LodgersSite.Client/Foo.cs coverage. Exact match
    # wins outright; otherwise take the LONGEST boundary-aligned suffix match
    # rather than whichever entry the dict yields first.
    best, best_len, best_br = None, -1, None
    for fname, lines in hit_by_file.items():
        if fname == path:
            return lines, br_by_file.get(fname, {})
        if fname.endswith("/" + path) or path.endswith("/" + fname):
            n = min(len(fname), len(path))
            if n > best_len:
                best, best_len, best_br = lines, n, br_by_file.get(fname, {})
    return best, (best_br or {})

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
br_total, br_covered, br_gaps = 0, 0, []   # branch coverage over CHANGED branch lines
for path, lns in changed.items():
    hits, branches = find_hits(path)
    if hits is None and declaration_only_file(path):
        continue                           # enum/interface-only file: no sequence points exist
    if hits is None and exclusion_attributed_file(path):
        continue                           # justified [ExcludeFromCodeCoverage] file: absent by design
    for ln in lns:
        if hits and ln not in hits:
            continue                       # instrumented file, non-executable line
        total += 1
        if hits is not None and hits.get(ln, 0) > 0:
            covered += 1
        else:
            unmatched.append(f"{path}:{ln}")
        # branch tally: only lines the instrumenter marked as branch points
        if ln in branches:
            c, t = branches[ln]
            br_total += t
            br_covered += c
            if c < t:
                br_gaps.append(f"{path}:{ln} ({c}/{t})")

pct = (covered / total * 100) if total else 100.0
bpct = (br_covered / br_total * 100) if br_total else 100.0
if verbose:
    print(f"diff-coverage: {covered}/{total} changed lines covered ({pct:.1f}%); "
          f"{br_covered}/{br_total} changed branches ({bpct:.1f}%)")
    if unmatched:
        print(f"  {len(unmatched)} changed lines uncovered (0 hits, or file never loaded by any test): "
              f"{'; '.join(unmatched[:50])}")
    if br_gaps:
        print(f"  {len(br_gaps)} changed branch lines partially covered: {'; '.join(br_gaps[:20])}")

fail = False
if pct < min_pct:
    print(f"::error::diff-coverage line {pct:.1f}% below minimum {min_pct}%")
    fail = True
if bpct < min_branch:
    print(f"::error::diff-coverage branch {bpct:.1f}% below minimum {min_branch}% "
          f"(untested branches on changed lines)")
    fail = True

if fail:
    sys.exit(0 if dry_run else 1)
print(f"diff-coverage line {pct:.1f}% >= {min_pct}%, branch {bpct:.1f}% >= {min_branch}% — pass")
PY
