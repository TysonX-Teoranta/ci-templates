#!/usr/bin/env bash
# parse-diagnostics.sh — turn a raw MSBuild log into structured findings.
#
# Reads an MSBuild/dotnet-build log and extracts every analyzer diagnostic into a
# machine-readable JSON report + a human text report. Deterministic, jq-free.
#
# Args: <raw-log> <scope> <mode> <findings-json> <findings-txt> [in-scope-file ...]
#   scope        diff|whole — in diff mode only findings in the listed files count.
#   in-scope-file repo-relative paths (from `git diff`) used to filter diff scope.
#
# MSBuild diagnostic line shape:
#   /abs/path/File.cs(12,5): warning CS1591: Missing XML comment ... [/path/Proj.csproj]
# We capture: file, line, col, severity, rule, message. NU19xx (NuGet audit) are
# excluded — security-reviewed suppressions, not code-quality findings — as is all
# generated code (obj/bin, EF Migrations, *.Designer.cs, *.g.cs, *ModelSnapshot.cs).

set -uo pipefail

RAW_LOG=$1; SCOPE=$2; MODE=$3; OUT_JSON=$4; OUT_TXT=$5; shift 5
IN_SCOPE=("$@")

_json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}; s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

# in_scope <abs-or-rel-path> — true if whole scope, or the path matches a diff file.
in_scope() {
  [ "$SCOPE" = "whole" ] && return 0
  local p=$1 f
  for f in "${IN_SCOPE[@]}"; do
    # Match on suffix so absolute build paths line up with repo-relative diff paths.
    case "$p" in *"$f") return 0 ;; esac
  done
  return 1
}

: > "$OUT_TXT"
tmp_json=$(mktemp)
count=0

# Diagnostic matcher: path(line,col): sev RULE: message
# Rule pattern: 2+ uppercase letters then digits (CS, CA, SA, IDE, ...).
diag_re='^(.+)\(([0-9]+),([0-9]+)\): (error|warning) ([A-Z]{2,}[0-9]+): (.*)$'

# MSBuild duplicates: with warnings-as-errors the compiler reports each diagnostic
# both inline and in the trailing error list, so the same (file,line,col,rule) shows
# up twice in the raw log. Count each real finding once.
declare -A seen

# tr '\r' '\n': dotnet writes progress lines with bare carriage returns, so a raw
# log line can be "Time Elapsed 00:0\r/path/File.cs(3,14): error ..." — read splits
# on \n only and the junk prefix would corrupt the captured file path.
while IFS= read -r line; do
  [[ $line =~ $diag_re ]] || continue
  file=${BASH_REMATCH[1]}
  lno=${BASH_REMATCH[2]}
  col=${BASH_REMATCH[3]}
  sev=${BASH_REMATCH[4]}
  rule=${BASH_REMATCH[5]}
  msg=${BASH_REMATCH[6]}
  # Drop NuGet audit (security-reviewed, not code-quality), and generated code:
  # obj/bin, EF Core Migrations, designer/g.cs/ModelSnapshot/AssemblyInfo/GlobalUsings.
  # None of it is hand-maintained, so it is never a valid zero-tolerance target.
  case "$rule" in NU*) continue ;; esac
  case "$file" in
    */obj/*|*/bin/*|*/Migrations/*) continue ;;
    *.Designer.cs|*.g.cs|*ModelSnapshot.cs|*.AssemblyInfo.cs) continue ;;
  esac
  msg=${msg% \[*.csproj\]}
  in_scope "$file" || continue
  key="$sev|$rule|$file|$lno|$col"
  [ -n "${seen[$key]:-}" ] && continue
  seen[$key]=1
  count=$((count + 1))
  printf '%s\t%s\t%s\t%s:%s\t%s\n' "$sev" "$rule" "$file" "$lno" "$col" "$msg" >> "$OUT_TXT"
  printf '{"severity":"%s","rule":"%s","file":"%s","line":%s,"col":%s,"message":"%s"}\n' \
    "$sev" "$rule" "$(_json_escape "$file")" "$lno" "$col" "$(_json_escape "$msg")" >> "$tmp_json"
done < <(tr '\r' '\n' < "$RAW_LOG")

# Emit findings.json: header + comma-joined objects.
{
  printf '{"contract":"C178289477824693","scope":"%s","mode":"%s","total_analyzer":%s,"findings":[' \
    "$SCOPE" "$MODE" "$count"
  paste -sd, "$tmp_json" 2>/dev/null
  printf ']}\n'
} > "$OUT_JSON"
rm -f "$tmp_json"

# Per-rule tally to stderr for the live log.
if [ "$count" -gt 0 ]; then
  echo "  per-rule tally:" >&2
  cut -f2 "$OUT_TXT" | sort | uniq -c | sort -rn | sed 's/^/    /' >&2
fi
exit 0
