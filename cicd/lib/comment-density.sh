#!/usr/bin/env bash
# comment-density.sh — Fleet V3
# PURPOSE: CICD v2 step 3 (C178289477824693) zero-tolerance gate. Fails any .cs file
# whose comment-to-code line ratio falls below a minimum threshold. Deterministic,
# no AI. Catches absence of comments, not quality (that's the compiler CS1591 gate).
#
# Usage: comment-density.sh --min <ratio> [--scope diff|whole-repo] [--base <ref>] [--dry-run] [-v] [-h]
set -euo pipefail

MIN="0.05"
SCOPE="diff"
BASE="origin/main"
DRY_RUN=0
VERBOSE=0

usage() { grep '^# Usage' "$0" | sed 's/^# //'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --min) MIN="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [ "$SCOPE" = "diff" ]; then
  mapfile -t FILES < <(git diff --name-only --diff-filter=ACMR "${BASE}...HEAD" -- '*.cs' 2>/dev/null \
    | grep -v -E '/(obj|bin)/|\.g\.cs$|\.Designer\.cs$' || true)
else
  mapfile -t FILES < <(find . -name '*.cs' -not -path '*/obj/*' -not -path '*/bin/*' \
    -not -name '*.g.cs' -not -name '*.Designer.cs')
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  [ "$VERBOSE" = 1 ] && echo "comment-density: no .cs files in scope ($SCOPE) — pass"
  exit 0
fi

FAIL=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  code_lines=$(grep -cvE '^\s*(//|/\*|\*|$)' "$f")
  comment_lines=$(grep -cE '^\s*(//|/\*|\*)' "$f")
  [ "$code_lines" -eq 0 ] && continue
  ratio=$(awk -v c="$comment_lines" -v n="$code_lines" 'BEGIN{printf "%.4f", c/n}')
  below=$(awk -v r="$ratio" -v m="$MIN" 'BEGIN{print (r < m)}')
  if [ "$below" -eq 1 ]; then
    echo "::error file=$f::comment-density ${ratio} below minimum ${MIN}"
    FAIL=1
  elif [ "$VERBOSE" = 1 ]; then
    echo "$f: ${ratio} (ok)"
  fi
done

if [ "$FAIL" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  exit 1
fi
[ "$FAIL" -eq 1 ] && echo "comment-density: violations found (dry-run, not failing)"
exit 0
