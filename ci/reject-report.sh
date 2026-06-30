#!/usr/bin/env bash
# ci/reject-report.sh <site> <env> <stamp> [contract_id] — emit an AUTO reject-report.
#
# Called by rc-gate.sh whenever an ingestion oracle (A2/A4) finds forbidden content. Reads the
# scanner hits on stdin ("file:line:match" per line) and produces a structured report carrying:
#   · WHAT failed   (the hits)
#   · WHY           (the env's forbidden-content rule)
#   · REQUIRED FIXES (one actionable item per hit — dev's worklist for the next cut)
#
# The report is ATTACHED TO THE RC CONTRACT (SPEC §7): written into the RC contract's attachment
# area and the dev controllers' issues/ dir, and — when crom-contract is reachable — appended to
# the contract ledger as a block note. The RC is NOT failed/closed; re-entry re-fires the step.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SITE="${1:?site}"; ENV="${2:?env}"; STAMP="${3:?stamp}"; CONTRACT_ID="${4:-${RC_CONTRACT_ID:-}}"
HITS="$(cat)"
NOW="$(date -u +%FT%TZ)"

# Derive an actionable required-fix line per hit. Hits look like "file:line:match" (preferred)
# or "line:match"; the match itself may contain ':' (e.g. URLs), so parse the location prefix
# with a regex rather than splitting on every colon.
required_fixes() {
  printf '%s\n' "$HITS" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    local loc m
    if [[ "$line" =~ ^([^:]+):([0-9]+):(.*)$ ]]; then
      loc="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"; m="${BASH_REMATCH[3]}"
    elif [[ "$line" =~ ^([0-9]+):(.*)$ ]]; then
      loc="line ${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
    else
      loc="?"; m="$line"
    fi
    printf -- '- [ ] %s — remove, or wrap in <!-- DEV-ONLY:START -->…<!-- DEV-ONLY:END --> : %s\n' \
      "$loc" "$(printf '%s' "$m" | sed 's/^[[:space:]]*//' | cut -c1-100)"
  done
}

WHY="env=$ENV forbids dev-only / debug / internal-host content"
[ "$ENV" = "live" ] && WHY="$WHY, plus sample/seed/demo-data GENERATION"

REPORT="$(cat <<EOF
# RC REJECTED — $SITE $STAMP @ $ENV
_auto reject-report · $NOW · contract: ${CONTRACT_ID:-<unset>}_

## What failed (ingestion oracle hits)
\`\`\`
$(printf '%s\n' "$HITS" | head -100)
\`\`\`

## Why
$WHY. A release candidate carrying this content cannot enter $ENV.

## Required fixes (dev worklist for the next cut)
$(required_fixes)

## Re-entry
RC was NOT deployed and the contract stays OPEN. Fix the items above on dev, re-cut the RC
(A1), and re-promote — this step re-fires automatically.
EOF
)"

# 1. RC contract attachment area (repo-local, travels with the contract).
ATTACH_DIR="${RC_CONTRACT_DIR:-$REPO_ROOT/.rc-contract/rejects}"
mkdir -p "$ATTACH_DIR" 2>/dev/null || true
ATTACH="$ATTACH_DIR/RC-REJECT-${SITE}-${ENV}-${STAMP}.md"
printf '%s\n' "$REPORT" > "$ATTACH" 2>/dev/null && note "reject-report attached to RC contract: $ATTACH" || warn "could not write $ATTACH"

# 2. Dev controllers' issues/ dir (orchestrator picks it up to route the reject back to dev).
ISSUES="${RC_ORCH_ISSUES_DIR:-/home/deploy/repo/lodgers-fleet/issues}"
mkdir -p "$ISSUES" 2>/dev/null && cp -f "$ATTACH" "$ISSUES/RC-REJECT-${SITE}-${ENV}-${STAMP}.md" 2>/dev/null \
  && note "reject-report filed to orchestrator issues: $ISSUES" || true

# 3. Contract ledger (block note) when crom-contract + a contract id are available.
if [ -n "$CONTRACT_ID" ] && command -v crom-contract >/dev/null 2>&1; then
  crom-contract block "$CONTRACT_ID" "RC $SITE/$STAMP REJECTED @ $ENV — see $ATTACH (reasons+required-fixes)" >/dev/null 2>&1 \
    && note "contract $CONTRACT_ID annotated with reject" || true
fi

printf '%s\n' "$ATTACH"
