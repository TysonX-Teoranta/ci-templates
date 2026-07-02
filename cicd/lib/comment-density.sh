#!/usr/bin/env bash
# comment-density.sh — custom zero-tolerance check: every source file must carry a
# minimum ratio of comment lines to code lines (PLAN.md step 3, comment-density rule).
#
# Deterministic, language-aware-enough for C#: counts // line comments, /* */ block
# comments and /// doc comments as COMMENT lines; non-blank non-comment lines as CODE.
# A file fails when comments/code < MIN_RATIO (default 0.10) AND it has more than
# MIN_CODE_LINES lines of code (tiny files are exempt to avoid noise).
#
# Args: [--report-append <txt>] [--min-ratio R] [--min-code N] <file.cs> [file.cs ...]
# Output: prints the NUMBER OF FAILING FILES to stdout (machine-readable), detail to
# stderr / the appended report. Exit 0 always (the caller decides the verdict).

set -uo pipefail

MIN_RATIO="${CICD_MIN_COMMENT_RATIO:-0.10}"
MIN_CODE=15
REPORT=""
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --report-append) REPORT="${2:-}"; shift 2 ;;
    --min-ratio)     MIN_RATIO="${2:-}"; shift 2 ;;
    --min-code)      MIN_CODE="${2:-}"; shift 2 ;;
    *)               FILES+=("$1"); shift ;;
  esac
done

fails=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  # awk computes comment vs code lines, tracking /* */ block state, then applies
  # the ratio gate. Prints "FAIL <ratio> <comments> <code>" or "OK".
  read -r verdict ratio comments code < <(
    awk '
      BEGIN { c=0; k=0; inblk=0 }
      {
        line=$0
        sub(/^[ \t]+/, "", line)
        if (inblk) { c++; if (line ~ /\*\//) inblk=0; next }
        if (line == "") next
        if (line ~ /^\/\//) { c++; next }                 # // or /// comment
        if (line ~ /^\/\*/) { c++; if (line !~ /\*\//) inblk=1; next }
        k++                                                # code line
      }
      END {
        r = (k>0) ? c/k : 1
        printf("%s %.3f %d %d", (r<MINR && k>MINC) ? "FAIL" : "OK", r, c, k)
      }
    ' MINR="$MIN_RATIO" MINC="$MIN_CODE" "$f"
  )
  if [ "$verdict" = "FAIL" ]; then
    fails=$((fails + 1))
    rel=${f#"$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null)"/}
    line="warning\tCOMMENT_DENSITY\t${rel:-$f}\t1:1\tcomment/code ratio ${ratio} < ${MIN_RATIO} (${comments} comment / ${code} code lines)"
    printf '%b\n' "$line" >&2
    [ -n "$REPORT" ] && printf '%b\n' "$line" >> "$REPORT"
  fi
done

printf '%s\n' "$fails"
exit 0
