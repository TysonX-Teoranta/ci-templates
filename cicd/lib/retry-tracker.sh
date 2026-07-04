#!/usr/bin/env bash
# retry-tracker.sh — Fleet V3
# PURPOSE: CICD v2 step 3 (C178289477824693) silent retry/elevation loop. Tracks
# consecutive zero-tolerance-gate failures on a PR via a numeric label
# (zt-fail-N). On the gate going green, clears the counter. On the 10th
# consecutive fail, adds a `step3-elevate` label + a PR comment (silent — no
# email) so a human/Crom notices without pulseai retrying forever. Deterministic,
# no AI: this script only counts and labels; pulseai is invoked separately (by
# the caller) to actually rework the code.
#
# Requires: gh CLI authenticated (GITHUB_TOKEN), run inside a PR-triggered workflow.
# Usage: retry-tracker.sh --pr <number> --repo <owner/repo> --result <pass|fail> [--limit <n>] [--dry-run] [-v] [-h]
set -euo pipefail

PR="" REPO="" RESULT="" LIMIT=10 DRY_RUN=0 VERBOSE=0

usage() { grep '^# Usage' "$0" | sed 's/^# //'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --result) RESULT="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$PR" ] || [ -z "$REPO" ] || [ -z "$RESULT" ]; then
  echo "--pr, --repo, --result required" >&2; exit 1
fi
case "$RESULT" in
  pass|fail) ;;
  *) echo "--result must be pass|fail" >&2; exit 1 ;;
esac

# A failed label read must FAIL the step, not silently zero the counter — a
# zeroed CURRENT resets the consecutive-failure budget and strands stale
# zt-fail-N labels, so an API blip would quietly defeat the elevation limit.
if ! LABELS=$(gh api "repos/${REPO}/issues/${PR}/labels" --jq '.[].name'); then
  echo "retry-tracker: gh api label read failed for ${REPO}#${PR} — refusing to proceed with a zeroed counter" >&2
  exit 1
fi
# Every zt-fail-* present (at most one is expected; stale extras from earlier
# partial runs are all cleared below). CURRENT = the highest counter seen.
mapfile -t ZT_LABELS < <(printf '%s\n' "$LABELS" | grep -E '^zt-fail-[0-9]+$' || true)
CURRENT=0
if [ "${#ZT_LABELS[@]}" -gt 0 ]; then
  CURRENT=$(printf '%s\n' "${ZT_LABELS[@]}" | sed 's/zt-fail-//' | sort -rn | head -1)
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then echo "+ $*"; else "$@"; fi
}
clear_current() {
  # Remove ALL zt-fail-* labels, not just the one read — a leftover duplicate
  # would otherwise stick to the PR forever.
  local l
  for l in "${ZT_LABELS[@]}"; do
    run gh api -X DELETE "repos/${REPO}/issues/${PR}/labels/${l}" >/dev/null 2>&1 || true
  done
}

if [ "$RESULT" = pass ]; then
  [ "$VERBOSE" -eq 1 ] && echo "retry-tracker: gate green, clearing zt-fail-${CURRENT} (if any)"
  clear_current
  exit 0
fi

NEXT=$((CURRENT + 1))
[ "$VERBOSE" -eq 1 ] && echo "retry-tracker: gate red, ${CURRENT} -> ${NEXT} (limit ${LIMIT})"
clear_current
run gh api "repos/${REPO}/issues/${PR}/labels" -f "labels[]=zt-fail-${NEXT}" >/dev/null

if [ "$NEXT" -ge "$LIMIT" ]; then
  run gh api "repos/${REPO}/issues/${PR}/labels" -f "labels[]=step3-elevate" >/dev/null
  run gh api "repos/${REPO}/issues/${PR}/comments" \
    -f body="step3 zero-tolerance gate: ${NEXT} consecutive failed rework attempts (limit ${LIMIT}). Elevating — silent, no email. Needs a human/Crom decision on this change." >/dev/null
fi
