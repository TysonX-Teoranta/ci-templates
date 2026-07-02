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
Build succeeded with 3 warning(s)
EOF

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

# --- Verdict ------------------------------------------------------------------
log "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
