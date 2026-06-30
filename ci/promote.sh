#!/usr/bin/env bash
# ci/promote.sh <staging|live> — GATE A2 (dev->staging) / live-prep + A4 (staging->live).
#
# Driver = sh (zero human, no confirm-phrase). The TOTP gate that guards staging->live (G6) is
# NOT here — it fires in the workflow as a separate pulse-runner job (gate-wait.sh ... promote)
# BEFORE this script's live target runs. This script only does the deterministic promotion work.
#
#   target=staging : checkout RC tag at dev HEAD, INGEST re-verify (oracle, A2), strip tests,
#                    verify stripped build, open promote/<rc> PR into <staging branch>.
#   target=live    : diff <staging> vs <live>, INGEST re-verify against the live ruleset (A4),
#                    open PR <staging> -> <live>.
#
# Env (from the thin YAML caller):
#   SOLUTION, DOMAIN, DEV_BRANCH, STAGING_BRANCH, LIVE_BRANCH, DOMAIN_URL,
#   RUN_STRIP_TESTS(default true), CI_SKIP_BUILD(default 0)
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Per-domain RC config (KB_GATE etc.) — see ci/rc.conf. The ONLY intended spine divergence besides
# rc-forbidden.txt; sourced after lib.sh so CI_DIR is set. Absent -> the defaults below apply.
[ -r "$CI_DIR/rc.conf" ] && . "$CI_DIR/rc.conf"
KB_GATE="${KB_GATE:-0}"

TARGET="${1:?usage: promote.sh <staging|live>}"
SOLUTION="${SOLUTION:?SOLUTION required}"
DOMAIN="${DOMAIN:?DOMAIN required}"
DEV_BRANCH="${DEV_BRANCH:?DEV_BRANCH required}"
STAGING_BRANCH="${STAGING_BRANCH:?STAGING_BRANCH required}"
LIVE_BRANCH="${LIVE_BRANCH:?LIVE_BRANCH required}"
DOMAIN_URL="${DOMAIN_URL:-}"
RUN_STRIP_TESTS="${RUN_STRIP_TESTS:-true}"
CI_SKIP_BUILD="${CI_SKIP_BUILD:-0}"
cd "$REPO_ROOT"

# Ensure base branch <1> exists on origin; the first promotion bootstraps it from seed <2>.
# All remote mutations go through run_or_echo (DRY_RUN-safe). Fail-closed if neither exists,
# so the gate never silently opens a PR against a non-existent base (the A2 exit-1 root cause).
ensure_remote_base() {
  local base="$1" seed="$2"
  if git ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1; then
    log "base branch origin/$base present"
    return 0
  fi
  warn "base branch '$base' absent on origin — bootstrapping it from '$seed' (first promotion)."
  git ls-remote --exit-code --heads origin "$seed" >/dev/null 2>&1 \
    || die "cannot bootstrap base '$base': seed branch '$seed' also absent on origin."
  run_or_echo "git fetch --no-tags origin '$seed'"
  run_or_echo "git push origin 'FETCH_HEAD:refs/heads/$base'"
  note "bootstrapped base branch '$base' from '$seed'."
}

promote_staging() {
  stage "A2.1 — locate RC tag at $DEV_BRANCH HEAD"
  local DEV_HEAD RC_TAG
  DEV_HEAD=$(git rev-parse HEAD)
  RC_TAG=$( { git tag --points-at "$DEV_HEAD" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-rc\.' || true; } | sort -V | tail -1)
  [ -n "$RC_TAG" ] || die "no RC tag at $DEV_BRANCH HEAD — run Create RC (A1) first."
  set_out RC_TAG "$RC_TAG"
  log "RC_TAG=$RC_TAG"

  stage "A2.1b — Check4: dependency-lock integrity (RC tag vs dev HEAD, build-once)"
  # Fail closed if the resolved dependency set drifted between the RC cut ($RC_TAG) and the dev
  # HEAD now being promoted: a post-cut transitive/lock bump means the RC artifact is stale and
  # must be re-cut, never promoted. Runs BEFORE the RC checkout so HEAD is still the dev tip.
  bash "$CI_DIR/check-deplock.sh" "$RC_TAG" .

  run_or_echo "git checkout '$RC_TAG'"

  stage "A2.2 — RC INGESTION ORACLE (staging re-verify, DIR-085)"
  RC_STAMP="$RC_TAG" bash "$SCRIPTS_DIR/rc-gate.sh" ingest staging "$DOMAIN" .

  if [ "$KB_GATE" = "1" ]; then
    stage "A2.2b — KB FULL RE-VERIFY (bundle integrity vs RC-committed manifest, C178197393523617)"
    # Re-derive the KB content signature from the checked-out RC and HARD-gate it against the
    # manifest committed at cut time: blocks the promotion if the KB drifted/tampered since the
    # cut. The per-tier row-count verify runs at deploy (kb/load-p0.sh vs the tier own registry).
    # Domain-gated by KB_GATE (ci/rc.conf): only the tysonx KB pipeline sets it; no-op elsewhere.
    bash "$CI_DIR/kb-gate.sh"
  fi

  if [ "$RUN_STRIP_TESTS" = "true" ]; then
    stage "A2.3 — strip test projects"
    SOLUTION="$SOLUTION" bash "$SCRIPTS_DIR/strip-tests.sh"
  else
    stage "A2.3 — strip test projects (SKIPPED: RUN_STRIP_TESTS=false)"
  fi

  if [ "$CI_SKIP_BUILD" = "1" ]; then
    stage "A2.4 — verify stripped build (SKIPPED: CI_SKIP_BUILD=1)"
  else
    stage "A2.4 — verify stripped build"
    dotnet build "$SOLUTION" --configuration Release --verbosity quiet
  fi

  stage "A2.5 — open promotion PR (promote/$RC_TAG -> $STAGING_BRANCH)"
  local BRANCH="promote/$RC_TAG"
  git config user.name  "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  run_or_echo "git checkout -B '$BRANCH'"
  run_or_echo "git add -A"
  run_or_echo "git commit -m 'chore: strip test projects for staging promotion ($RC_TAG)'" || true
  run_or_echo "git push --force-with-lease origin '$BRANCH'"
  ensure_remote_base "$STAGING_BRANCH" "$LIVE_BRANCH"
  if [ "$DRY_RUN" = "1" ]; then
    note "DRY-RUN: would open PR base=$STAGING_BRANCH head=$BRANCH (idempotent: skips if a promote/* PR is already open)"
    return 0
  fi
  local EXISTING
  EXISTING=$(gh pr list --base "$STAGING_BRANCH" --state open --json headRefName \
    -q '.[] | select(.headRefName|startswith("promote/")) | .headRefName' | head -1)
  [ -n "$EXISTING" ] && { note "promotion PR already open ($EXISTING)."; return 0; }
  gh pr create --base "$STAGING_BRANCH" --head "$BRANCH" \
    --title "Release $RC_TAG: Dev → Staging" \
    --body "Promotion of \`$RC_TAG\` to staging. Validate on ${DOMAIN_URL} after deploy."
  note "A2 OK — staging promotion PR opened for $RC_TAG"
}

promote_live() {
  stage "live-prep — diff $STAGING_BRANCH vs $LIVE_BRANCH"
  run_or_echo "git fetch origin '$LIVE_BRANCH'"
  local DIFF
  DIFF=$(git log "origin/${LIVE_BRANCH}..origin/${STAGING_BRANCH}" --oneline 2>/dev/null || true)
  if [ -z "$DIFF" ]; then note "live already up to date — nothing to promote."; set_out NO_DIFF true; return 0; fi
  local LATEST_RC RELEASE_TAG
  LATEST_RC=$(git tag -l 'v*-rc.*' --sort=-version:refname --merged "origin/${STAGING_BRANCH}" 2>/dev/null | head -1 || true)
  [ -n "$LATEST_RC" ] || LATEST_RC=$( { git tag -l 'v*-rc.*' --sort=-version:refname || true; } | head -1)
  RELEASE_TAG="v$(echo "$LATEST_RC" | sed 's/^v//;s/-rc\.[0-9]*//')"
  set_out RELEASE_TAG "$RELEASE_TAG"; set_out LATEST_RC "$LATEST_RC"
  log "RELEASE_TAG=$RELEASE_TAG (from $LATEST_RC)"

  stage "A4 — RC INGESTION ORACLE (live re-verify, DIR-085)"
  RC_STAMP="$LATEST_RC" bash "$SCRIPTS_DIR/rc-gate.sh" ingest live "$DOMAIN" .

  stage "live-prep — open promotion PR ($STAGING_BRANCH -> $LIVE_BRANCH)"
  if [ "$DRY_RUN" = "1" ]; then
    note "DRY-RUN: would open PR base=$LIVE_BRANCH head=$STAGING_BRANCH (release $RELEASE_TAG from $LATEST_RC)"
    return 0
  fi
  local EXISTING
  EXISTING=$(gh pr list --base "$LIVE_BRANCH" --head "$STAGING_BRANCH" --state open --json number -q '.[0].number')
  [ -n "$EXISTING" ] && { note "live PR #$EXISTING already open."; return 0; }
  gh pr create --base "$LIVE_BRANCH" --head "$STAGING_BRANCH" \
    --title "Release ${RELEASE_TAG}: Staging → Live" \
    --body "Release ${RELEASE_TAG} (from ${LATEST_RC}). After merge run Deploy — Live (TOTP-gated, G8)."
  note "A4 OK — live promotion PR opened for $RELEASE_TAG"
}

case "$TARGET" in
  staging) promote_staging ;;
  live)    promote_live ;;
  *) die "unknown target '$TARGET' (want staging|live)" ;;
esac
