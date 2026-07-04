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
else
  warn "python3/git not present — skipping diff-coverage selftests"
fi

# --- Verdict ------------------------------------------------------------------
log "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
