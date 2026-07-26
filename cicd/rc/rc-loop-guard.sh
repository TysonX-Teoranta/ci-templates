#!/usr/bin/env bash
# rc-loop-guard.sh — bounded RC refusal loop + single-shot escalation (zero AI).
#
# THE RC LOOP IS BOUNDED (Crom, 2026-07-26). A refused cut is NOT a failure: with a
# clearance path it loops silently (issue refreshed, no mail; essentials-only). This
# guard turns that unbounded loop into a bounded one with exactly one notification:
#
#   attempts 1 .. N-1 : silent loop  (issue refreshed, NO mail)
#   attempt  N (== cap): TERMINAL     (stop auto-recut; ONE essential mail + decision card)
#   "no clearance path": TERMINAL immediately, regardless of the counter (product decision)
#
# So the loop never runs forever AND Crom is always notified exactly once, within a
# known bound. N defaults to 5 for every domain and is adjustable per domain via the
# `loop_cap` field in domains.yml (Crom-owned registry; a change rides a reviewed PR —
# AI can propose but cannot relax it at runtime).
#
# The attempt counter is deterministic state carried in the rc-refusal issue body as a
# machine marker: <!-- rc-attempts: N -->. Terminal state is the `rc-terminal` label,
# which the per-repo rc-reloop workflow honours to stop auto-recutting.
#
# Env in : DOMAIN, REPO (org/name), RUN_ID, RUN_URL, GH_TOKEN, and CICD_REGISTRY
#          (path to the ci-templates domains.yml this run checked out).
# Side-effects: files/refreshes the rc-refusal issue; at terminal writes a Crom decision
#          card to ~/crom-queue/pending and sends ONE essential mail via sendmail.
# Exit  : 0 always (a refusal is a normal, handled event; the finalise verdict already failed).
#
# printf format strings below carry literal markdown backticks for the issue/mail bodies;
# every dynamic value is passed via %s args, so nothing is meant to expand in single quotes.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$HERE/.." && pwd)/lib/common.sh"

DOMAIN="${DOMAIN:?DOMAIN required}"
REPO="${REPO:?REPO required}"
RUN_ID="${RUN_ID:?RUN_ID required}"
RUN_URL="${RUN_URL:?RUN_URL required}"
require gh
require awk

# --- Loop cap N (per-domain, default 5) --------------------------------------
CAP="$(domain_field "$DOMAIN" loop_cap 2>/dev/null || true)"
case "$CAP" in ''|*[!0-9]*) CAP=5 ;; esac
[ "$CAP" -ge 1 ] 2>/dev/null || CAP=5

# --- Gate reasons from the failed run ----------------------------------------
REASONS="$(gh run view "$RUN_ID" -R "$REPO" --log-failed 2>/dev/null \
  | grep -o '##\[error\].*' | sed 's/##\[error\]//' | awk '!seen[$0]++' | head -20)"
[ -n "$REASONS" ] || REASONS='(could not extract gate errors — read the run log)'

NO_CLEARANCE=0
printf '%s' "$REASONS" | grep -qi 'no clearance path' && NO_CLEARANCE=1

# --- Ensure labels exist ------------------------------------------------------
gh label create rc-refusal -R "$REPO" \
  --description 'RC finalise refused — fix on dev, closing this issue re-orders the cut' \
  --color B60205 2>/dev/null || true
gh label create rc-terminal -R "$REPO" \
  --description 'RC loop bounded out — stopped auto-recut, awaiting Crom' \
  --color 000000 2>/dev/null || true

# --- Find the one open rc-refusal issue + its prior attempt count -------------
NUM="$(gh issue list -R "$REPO" --label rc-refusal --state open \
  --json number -q '.[0].number' 2>/dev/null)"
PRIOR=0
if [ -n "$NUM" ]; then
  BODY_OLD="$(gh issue view "$NUM" -R "$REPO" --json body -q .body 2>/dev/null || true)"
  PRIOR="$(printf '%s' "$BODY_OLD" | sed -n 's/.*<!-- rc-attempts: \([0-9][0-9]*\) -->.*/\1/p' | head -1)"
  case "$PRIOR" in ''|*[!0-9]*) PRIOR=0 ;; esac
fi
ATTEMPT=$((PRIOR + 1))

TERMINAL=0
[ "$NO_CLEARANCE" -eq 1 ] && TERMINAL=1
[ "$ATTEMPT" -ge "$CAP" ] && TERMINAL=1

log "rc-loop-guard: $DOMAIN attempt $ATTEMPT/$CAP (no-clearance=$NO_CLEARANCE) terminal=$TERMINAL"

# --- Compose the issue body (carries the counter marker) ----------------------
BODY_FILE="$(mktemp)"
{
  printf '<!-- rc-attempts: %s -->\n' "$ATTEMPT"
  printf 'RC finalise for **%s** was refused by the hygiene gates. No candidate was cut; the slot is unchanged.\n\n' "$DOMAIN"
  printf '**Attempt %s of %s** before the loop bounds out and escalates to Crom.\n\n' "$ATTEMPT" "$CAP"
  printf '## Gate errors (fix each on `%s-dev` via normal dev PRs)\n\n' "$DOMAIN"
  printf '%s\n' "$REASONS" | while IFS= read -r l; do [ -n "$l" ] && printf -- '- [ ] %s\n' "$l"; done
  printf '\nRun: %s\n\n' "$RUN_URL"
  if [ "$TERMINAL" -eq 1 ]; then
    printf '**LOOP BOUNDED OUT — awaiting Crom.** Auto-recut is stopped (label `rc-terminal`). '
    printf 'Resolve (fix + remove `rc-terminal`, or `cicd rc %s drop`), then the loop resumes.\n' "$DOMAIN"
  else
    printf '**The loop is hands-free:** open the fix PR(s) into `%s-dev` with `Fixes #<this issue number>` in the description — automerge lands a green PR, the merge auto-closes this issue, and closing it auto-re-orders the RC cut. A clean cut mails the finalised notice.\n' "$DOMAIN"
  fi
} > "$BODY_FILE"

TITLE="[RC refused] $DOMAIN — hygiene gates blocked the cut"
if [ -n "$NUM" ]; then
  gh issue edit "$NUM" -R "$REPO" --title "$TITLE" --body-file "$BODY_FILE"
  gh issue comment "$NUM" -R "$REPO" --body "Refused again (attempt $ATTEMPT/$CAP) — reasons refreshed above. Run: $RUN_URL"
else
  ISSUE_URL="$(gh issue create -R "$REPO" --label rc-refusal --title "$TITLE" --body-file "$BODY_FILE")"
  NUM="${ISSUE_URL##*/}"
fi
ISSUE_URL="$(gh issue view "$NUM" -R "$REPO" --json url -q .url 2>/dev/null || echo "$RUN_URL")"
rm -f "$BODY_FILE"

# --- Not terminal: silent loop, essentials-only → NO mail ---------------------
if [ "$TERMINAL" -eq 0 ]; then
  note "rc-loop-guard: attempt $ATTEMPT/$CAP — silent loop, no mail (essentials-only)."
  exit 0
fi

# --- Terminal: label + Crom decision card + ONE essential mail ----------------
gh label create crom-decision -R "$REPO" \
  --description 'blocked on a Crom decision' --color 5319E7 2>/dev/null || true
gh issue edit "$NUM" -R "$REPO" --add-label rc-terminal --add-label crom-decision 2>/dev/null || true

if [ "$NO_CLEARANCE" -eq 1 ]; then
  REASON_LINE='at least one gate has no dev clearance path (product decision)'
else
  REASON_LINE="the refusal loop hit its bound (attempt $ATTEMPT of $CAP)"
fi

mkdir -p "$HOME/crom-queue/pending"
{
  printf '# RC decision needed — %s: loop bounded out\n' "$DOMAIN"
  printf '_%s. Decide, land the outcome on %s-dev (or drop), then remove `rc-terminal`/close the loop issue to resume._\n\n' "$REASON_LINE" "$DOMAIN"
  printf '%s\n\n' "$REASONS"
  printf 'Loop issue: %s\nRun: %s\n' "$ISSUE_URL" "$RUN_URL"
} > "$HOME/crom-queue/pending/RC-DECISION-$DOMAIN.md"

if command -v /usr/sbin/sendmail >/dev/null 2>&1; then
  {
    printf 'To: crom@tysonx.ie\n'
    printf 'From: crom@tysonx.ie\n'
    printf 'Auto-Submitted: auto-generated\n'
    printf 'Subject: [RC] %s bounded out — needs your decision\n\n' "$DOMAIN"
    printf 'The RC finalise for %s stopped looping: %s.\n' "$DOMAIN" "$REASON_LINE"
    printf 'Auto-recut is halted; the slot is unchanged. Decision card is in topdog (decisions queue).\n\n'
    printf 'Why (gate errors):\n%s\n\n' "$REASONS"
    printf 'Loop issue: %s\nBoard: cicd rc %s\nRun: %s\n' "$ISSUE_URL" "$DOMAIN" "$RUN_URL"
  } | /usr/sbin/sendmail -f crom@tysonx.ie -t
  note "rc-loop-guard: TERMINAL — escalated to Crom (decision card + one mail)."
else
  warn "rc-loop-guard: TERMINAL but /usr/sbin/sendmail absent — decision card written, mail skipped."
fi
exit 0
