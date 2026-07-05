#!/usr/bin/env bash
# selftest.sh — offline unit tests for the CICD v2 spine (contract C178289477824693).
#
# Proves the deterministic parsers behave correctly WITHOUT dotnet, GitHub or a
# checkout — the Fleet-V3 "offline-testable" invariant. Feeds each lib synthetic
# fixtures and asserts on the structured output. Exit 0 = all green, 1 = a failure.
#
# Run: cicd/selftest.sh [-v]
# Deterministic, zero-AI, no network. Safe to run anywhere bash + coreutils exist.

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091  # sourced sibling is linted separately; -x not used in shell-lint
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

[ "${1:-}" = "-v" ] && CICD_VERBOSE=1
export CICD_VERBOSE   # consumed by vlog() in the sourced common.sh

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ok <label> <actual> <expected> — assert string equality.
ok() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); vlog "PASS $1 ($2)"
  else
    FAIL=$((FAIL + 1)); err "FAIL $1: got '$2' expected '$3'"
  fi
}

# --- Fixture: a representative MSBuild diagnostic log --------------------------
cat > "$WORK/raw.log" <<'EOF'
  Determining projects to restore...
/repo/LodgersSite/Foo.cs(12,5): warning CS1591: Missing XML comment for publicly visible type [/repo/LodgersSite.csproj]
/repo/LodgersSite/Bar.cs(3,1): error CA1822: Member does not access instance data [/repo/LodgersSite.csproj]
/repo/LodgersSite.Tests/Baz.cs(9,9): warning SA1600: Elements should be documented [/repo/T.csproj]
/repo/LodgersSite.csproj : error NU1903: Warning As Error: known high severity vulnerability [/repo/x.sln]
/repo/LodgersSite/Migrations/20260101_Init.cs(5,1): warning CS1591: Missing XML comment [/repo/LodgersSite.csproj]
/repo/LodgersSite/Migrations/AppDbContextModelSnapshot.cs(9,1): warning CS1591: Missing XML comment [/repo/LodgersSite.csproj]
/repo/LodgersSite/Foo.Designer.cs(3,1): warning CS1591: Missing XML comment [/repo/LodgersSite.csproj]
/repo/LodgersSite/Foo.cs(12,5): warning CS1591: Missing XML comment for publicly visible type [/repo/LodgersSite.csproj]
Build succeeded with 3 warning(s)
EOF
# A \r-joined progress segment (dotnet writes "Time Elapsed …\r<diagnostic>") that
# duplicates Bar.cs(3,1) — must parse cleanly AND dedup, so whole-total stays 3.
printf 'Time Elapsed 00:00:04.32\r/repo/LodgersSite/Bar.cs(3,1): error CA1822: Member does not access instance data [/repo/LodgersSite.csproj]\n' >> "$WORK/raw.log"

PD="$CICD_ROOT/lib/parse-diagnostics.sh"
CD="$CICD_ROOT/lib/comment-density.sh"

# --- parse-diagnostics: whole scope counts all code findings, drops NU19xx +
#     generated code (Migrations / ModelSnapshot / *.Designer.cs) -----------------
bash "$PD" "$WORK/raw.log" whole measure "$WORK/w.json" "$WORK/w.txt"
total=$(sed -n 's/.*"total_analyzer":\([0-9]*\).*/\1/p' "$WORK/w.json")
ok "whole/total-excludes-NU+generated" "$total" "3"
ok "whole/txt-lines"         "$(wc -l < "$WORK/w.txt" | tr -d ' ')" "3"
ok "whole/no-NU-in-json"     "$(grep -c 'NU1903' "$WORK/w.json")" "0"
ok "whole/no-migrations"     "$(grep -c 'Migrations' "$WORK/w.json")" "0"
ok "whole/no-designer"       "$(grep -c 'Designer' "$WORK/w.json")" "0"
ok "whole/dedup-repeated-diag" "$(grep -c '"line":12' "$WORK/w.json")" "1"
ok "whole/cr-split-no-mangled-path" "$(grep -c 'Time Elapsed' "$WORK/w.json")" "0"
ok "whole/cr-diag-still-counted" "$(grep -c 'CA1822' "$WORK/w.json")" "1"

# --- parse-diagnostics: diff scope filters to listed files ---------------------
bash "$PD" "$WORK/raw.log" diff gate "$WORK/d.json" "$WORK/d.txt" LodgersSite/Foo.cs
dtotal=$(sed -n 's/.*"total_analyzer":\([0-9]*\).*/\1/p' "$WORK/d.json")
ok "diff/only-in-scope-file" "$dtotal" "1"
ok "diff/kept-rule-is-CS1591" "$(grep -o '"rule":"[^"]*"' "$WORK/d.json")" '"rule":"CS1591"'

# --- parse-diagnostics: diff-scope suffix match anchors on a path boundary —
#     a diagnostic in PrefixX/Sub/Foo.cs must NOT bind to in-scope X/Sub/Foo.cs;
#     absolute (/repo/X/…) and bare repo-relative paths both still match ---------
cat > "$WORK/anchor.log" <<'EOF'
/repo/X/Sub/Foo.cs(1,1): warning CS1591: Missing XML comment [/repo/P.csproj]
/repo/PrefixX/Sub/Foo.cs(2,2): warning CS1591: Missing XML comment [/repo/P.csproj]
X/Sub/Foo.cs(3,3): warning CS1591: Missing XML comment [/repo/P.csproj]
EOF
bash "$PD" "$WORK/anchor.log" diff gate "$WORK/a.json" "$WORK/a.txt" X/Sub/Foo.cs
atotal=$(sed -n 's/.*"total_analyzer":\([0-9]*\).*/\1/p' "$WORK/a.json")
ok "diff/suffix-match-boundary-anchored" "$atotal" "2"
ok "diff/prefix-lookalike-excluded" "$(grep -c 'PrefixX' "$WORK/a.json")" "0"

# --- registry reader: inline comments + trailing whitespace must not corrupt
#     values (quoted or bare); clean parses stay byte-identical ------------------
{
  printf 'version: 1\n\ndomains:\n'
  printf '  alpha:\n'
  printf '    repo: TysonX-Teoranta/alpha\n'
  printf '    status: active  # inline note must strip\n'
  printf '    app_dirs: "cicd .github" \n'
  printf '    dev_base: origin/main\n'
  printf '  beta:\n'
  printf '    status: "on-hold"\n'
  printf '    app_dirs: plain\t\n'
} > "$WORK/reg.yml"
REG_SAVE="$REGISTRY"
REGISTRY="$WORK/reg.yml"
ok "registry/inline-comment-stripped"  "$(domain_field alpha status)" "active"
ok "registry/quoted-trailing-ws"       "$(domain_field alpha app_dirs)" "cicd .github"
ok "registry/clean-bare-value"         "$(domain_field alpha dev_base)" "origin/main"
ok "registry/clean-quoted-value"       "$(domain_field beta status)" "on-hold"
ok "registry/bare-trailing-ws"         "$(domain_field beta app_dirs)" "plain"
ok "registry/domains-list"             "$(domains_list | paste -sd' ')" "alpha beta"
REGISTRY="$REG_SAVE"

# --- comment-density: dense file fails, tiny file exempt, commented file passes -
{ echo "public class X {"; for i in $(seq 1 20); do echo "  int v$i = $i;"; done; echo "}"; } > "$WORK/Dense.cs"
ok "density/dense-fails"   "$(bash "$CD" --min-code 15 "$WORK/Dense.cs" 2>/dev/null)" "1"
printf '// a\n// b\nint x=1;\n' > "$WORK/Small.cs"
ok "density/small-exempt"  "$(bash "$CD" "$WORK/Small.cs" 2>/dev/null)" "0"
{ for i in $(seq 1 20); do echo "// comment $i"; done; for i in $(seq 1 20); do echo "int v$i=$i;"; done; } > "$WORK/Good.cs"
ok "density/commented-passes" "$(bash "$CD" "$WORK/Good.cs" 2>/dev/null)" "0"

# --- json-lint: JSONC (appsettings*.json) allows comments, strict .json does not,
#     broken JSONC still fails, canonical strict formatting still enforced ---------
if command -v jq >/dev/null 2>&1; then
  JL="$CICD_ROOT/lib/json-lint.sh"
  printf '{\n  // ASP.NET reads this with JsonCommentHandling.Skip\n  "a": "http://x//y", /* inline */\n  "b": 1\n}\n' > "$WORK/appsettings.json"
  ok "json/jsonc-comments-pass"  "$(bash "$JL" "$WORK/appsettings.json" 2>/dev/null)" "0"
  printf '{\n  // comment\n  "a": ,\n}\n' > "$WORK/appsettings.Broken.json"
  ok "json/jsonc-broken-fails"   "$(bash "$JL" "$WORK/appsettings.Broken.json" 2>/dev/null)" "1"
  printf '{\n  // no comments allowed here\n  "a": 1\n}\n' > "$WORK/plain.json"
  ok "json/strict-comment-fails" "$(bash "$JL" "$WORK/plain.json" 2>/dev/null)" "1"
  printf '{\n  "a": 1\n}\n' > "$WORK/canon.json"
  ok "json/strict-canon-passes"  "$(bash "$JL" "$WORK/canon.json" 2>/dev/null)" "0"
  printf '{"a":1}\n' > "$WORK/uncanon.json"
  ok "json/strict-uncanon-fails" "$(bash "$JL" "$WORK/uncanon.json" 2>/dev/null)" "1"
else
  warn "jq not present — skipping json-lint selftests"
fi

# --- diff-coverage: cobertura-untracked lines (comments/braces) carry no test
#     burden; uncovered TRACKED lines still gate; unmatched files stay strict -----
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  DC="$CICD_ROOT/lib/diff-coverage.sh"
  R="$WORK/dcrepo"; mkdir -p "$R"
  git -C "$R" init -q
  printf 'int a=1;\nint b=2;\n' > "$R/File.cs"
  git -C "$R" add File.cs
  git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm base
  # HEAD adds two comment lines (not in cobertura) + one covered code line (line 4).
  printf 'int a=1;\n// why: context\n// more context\nint c=3;\nint b=2;\n' > "$R/File.cs"
  git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qam head
  cat > "$WORK/cov-hit.xml" <<'XML'
<coverage><packages><package><classes><class filename="File.cs">
<lines><line number="1" hits="1"/><line number="4" hits="1"/><line number="5" hits="1"/></lines>
</class></classes></package></packages></coverage>
XML
  (cd "$R" && bash "$DC" --cobertura "$WORK/cov-hit.xml" --min 80 --base HEAD~1 >/dev/null 2>&1)
  ok "diffcov/comment-lines-exempt" "$?" "0"
  # Same diff, but the one tracked changed line (4) is UNCOVERED — must fail.
  sed 's/number="4" hits="1"/number="4" hits="0"/' "$WORK/cov-hit.xml" > "$WORK/cov-miss.xml"
  (cd "$R" && bash "$DC" --cobertura "$WORK/cov-miss.xml" --min 80 --base HEAD~1 >/dev/null 2>&1)
  ok "diffcov/uncovered-tracked-fails" "$?" "1"
  # File absent from the report entirely — new untested file stays gated.
  cat > "$WORK/cov-none.xml" <<'XML'
<coverage><packages><package><classes><class filename="Other.cs">
<lines><line number="1" hits="1"/></lines>
</class></classes></package></packages></coverage>
XML
  (cd "$R" && bash "$DC" --cobertura "$WORK/cov-none.xml" --min 80 --base HEAD~1 >/dev/null 2>&1)
  ok "diffcov/unmatched-file-still-strict" "$?" "1"
  # A NEW test-project file (uncovered by design) must NOT gate — test code is not
  # coverage-bearing product code. Add an untested .cs under a .Tests/ project on top
  # of the covered product change; the gate must still pass (test file excluded).
  mkdir -p "$R/App.NUnit.Tests"
  printf 'int t1=1;\nint t2=2;\nint t3=3;\n' > "$R/App.NUnit.Tests/FooTests.cs"
  git -C "$R" add App.NUnit.Tests/FooTests.cs
  git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm tests
  (cd "$R" && bash "$DC" --cobertura "$WORK/cov-hit.xml" --min 80 --base HEAD~2 >/dev/null 2>&1)
  ok "diffcov/test-files-excluded" "$?" "0"
  # The app entry point Program.cs (top-level composition root, not unit-testable)
  # must NOT gate — an uncovered CLI-verb dispatch there would otherwise block the PR.
  printf 'if (args.Length > 0) { Run(); }\nreturn;\n' > "$R/Program.cs"
  git -C "$R" add Program.cs
  git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm program
  (cd "$R" && bash "$DC" --cobertura "$WORK/cov-hit.xml" --min 80 --base HEAD~3 >/dev/null 2>&1)
  ok "diffcov/entrypoint-excluded" "$?" "0"
  # Partial classes / nested types / async state machines each emit their own
  # <class filename="X.cs"> — their line hits must MERGE, not overwrite, or a covered
  # method in an early entry vanishes (lodgers #294: DbSeeder.cs, 43 class entries).
  # Here line 4 is covered ONLY in the first of two File.cs entries; the merge must
  # still see it as covered.
  cat > "$WORK/cov-partial.xml" <<'XML'
<coverage><packages><package><classes>
<class filename="File.cs"><lines><line number="4" hits="1"/></lines></class>
<class filename="File.cs"><lines><line number="1" hits="1"/><line number="5" hits="1"/></lines></class>
</classes></package></packages></coverage>
XML
  (cd "$R" && bash "$DC" --cobertura "$WORK/cov-partial.xml" --min 80 --base HEAD~3 >/dev/null 2>&1)
  ok "diffcov/partial-class-hits-merge" "$?" "0"
  # Method/ctor declaration lines carry NO sequence points, so the instrumenter
  # emits no entry for them and no test can ever cover them. A changed line ABSENT
  # from an otherwise-instrumented file must not gate even at min=100, or any PR
  # that adds/renames a method is permanently unmergeable (lodgers #300). Uncovered
  # BODIES stay gated: they appear as 0-hit ENTRIES (diffcov/uncovered-tracked-fails).
  printf 'int a=1;\n// why: context\n// more context\nint c=3;\nint b=2;\nvoid M(\n  int x)\n' > "$R/File.cs"
  git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qam decl
  (cd "$R" && bash "$DC" --cobertura "$WORK/cov-hit.xml" --min 100 --base HEAD~1 >/dev/null 2>&1)
  ok "diffcov/declaration-lines-exempt" "$?" "0"
else
  warn "python3/git not present — skipping diff-coverage selftests"
fi

# --- full-coverage: total floor gates; generated/test files exempt; partial
#     class entries merge; an empty report fails loudly, never passes vacuously ---
if command -v python3 >/dev/null 2>&1; then
  FC="$CICD_ROOT/lib/full-coverage.sh"
  # 3 of 4 product lines covered = 75%: passes a 70 floor, fails an 80 floor.
  cat > "$WORK/fc-mixed.xml" <<'XML'
<coverage><packages><package><classes><class filename="App/File.cs">
<lines><line number="1" hits="1"/><line number="2" hits="1"/><line number="3" hits="1"/><line number="4" hits="0"/></lines>
</class></classes></package></packages></coverage>
XML
  bash "$FC" --cobertura "$WORK/fc-mixed.xml" --min 70 >/dev/null 2>&1
  ok "fullcov/above-floor-passes" "$?" "0"
  bash "$FC" --cobertura "$WORK/fc-mixed.xml" --min 80 >/dev/null 2>&1
  ok "fullcov/below-floor-fails" "$?" "1"
  # Generated EF artifacts must not drag the total: the uncovered Migrations file
  # is excluded, leaving the covered product line = 100%.
  cat > "$WORK/fc-gen.xml" <<'XML'
<coverage><packages><package><classes>
<class filename="App/File.cs"><lines><line number="1" hits="1"/></lines></class>
<class filename="App/Migrations/20260101_Init.cs"><lines><line number="1" hits="0"/><line number="2" hits="0"/></lines></class>
</classes></package></packages></coverage>
XML
  bash "$FC" --cobertura "$WORK/fc-gen.xml" --min 100 >/dev/null 2>&1
  ok "fullcov/generated-excluded" "$?" "0"
  # Partial-class entries merge on max hits: line 1 covered in one entry only.
  cat > "$WORK/fc-partial.xml" <<'XML'
<coverage><packages><package><classes>
<class filename="App/File.cs"><lines><line number="1" hits="0"/></lines></class>
<class filename="App/File.cs"><lines><line number="1" hits="3"/></lines></class>
</classes></package></packages></coverage>
XML
  bash "$FC" --cobertura "$WORK/fc-partial.xml" --min 100 >/dev/null 2>&1
  ok "fullcov/partial-class-hits-merge" "$?" "0"
  # A report with zero coverable product lines = broken instrumentation → fail.
  cat > "$WORK/fc-empty.xml" <<'XML'
<coverage><packages></packages></coverage>
XML
  bash "$FC" --cobertura "$WORK/fc-empty.xml" --min 0 >/dev/null 2>&1
  ok "fullcov/empty-report-fails" "$?" "1"
else
  warn "python3 not present — skipping full-coverage selftests"
fi

# --- Verdict ------------------------------------------------------------------
log "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
