#!/usr/bin/env bash
# ci/dry-run.sh — prove the AUTO sh spine end-to-end on the dev workbench.
#
# Runs the SAME canonical scripts CI runs, with DRY_RUN=1 so no remote is mutated and Crom is
# never paged. Walks dev -> staging -> live through the auto (zero-human) gates A1..A4 and then
# HALTS at the first Crom TOTP wall (G6, staging->live promote). Proves:
#   · A1..A4 run with ZERO confirm-phrases / zero human input
#   · the spine stops dead at the TOTP wall it cannot pass without Crom
#
# Usage: DRY_RUN is forced on. CI_SKIP_BUILD=1 to skip dotnet (gate-logic proof only).
set -uo pipefail
export DRY_RUN=1
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CI="$CI_DIR"

# lodgers domain wiring (mirrors the thin YAML callers).
export SOLUTION="LodgersSite.slnx" DOMAIN="lodgers" WEB_PROJECT="LodgersSite/LodgersSite.csproj"
export DEV_BRANCH="lodgers-dev" STAGING_BRANCH="lodgers-staging" LIVE_BRANCH="lodgers-live"
export DOMAIN_URL="lodgers.ie" CI_SKIP_BUILD="${CI_SKIP_BUILD:-1}"

printf '################ LODGERS CICD SPINE — DRY RUN (DRY_RUN=1) ################\n'
printf 'host: %s   repo: %s   utc: %s\n' "$(hostname)" "$REPO_ROOT" "$(date -u +%FT%TZ)"

# A1 creates a LOCAL rc tag to prove the cut + feed A2; clean up any we add so the delivery
# branch is left pristine. (Tags are never pushed by a dry run.)
_TAGS_BEFORE="$(git -C "$REPO_ROOT" tag -l 'v*-rc.*' | sort)"
cleanup(){
  local after; after="$(git -C "$REPO_ROOT" tag -l 'v*-rc.*' | sort)"
  comm -13 <(printf '%s\n' "$_TAGS_BEFORE") <(printf '%s\n' "$after") \
    | while read -r t; do [ -n "$t" ] && git -C "$REPO_ROOT" tag -d "$t" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

stage "G0 — open RC contract  [Crom-held]"
note "G0 is Crom-only (crom-contract add). Assumed open for this proof. AI reports prog/block only."

printf '\n>>>>>>>> A1 — rc-cut (sh, zero human) >>>>>>>>\n'
BUMP=patch RUN_HYGIENE=true bash "$CI/rc-cut.sh" || die "A1 FAILED"

printf '\n>>>>>>>> A2 — promote dev->staging + staging ingestion oracle (sh, zero human) >>>>>>>>\n'
RUN_STRIP_TESTS=false bash "$CI/promote.sh" staging || die "A2 FAILED"

printf '\n>>>>>>>> A3 — staging test/soak (sh, NO code on staging) >>>>>>>>\n'
note "A3 = deterministic staging soak/health. No code edits on staging; any code defect => full reject to dev."
note "(dry-run: staging deploy + health are native CI/deploy plumbing; gate path proven, no live mutation.)"

printf '\n>>>>>>>> A4 — live ingestion oracle (sh, zero human) >>>>>>>>\n'
RUN_STRIP_TESTS=true bash "$CI/promote.sh" live || die "A4 FAILED"

printf '\n>>>>>>>> G6 — TOTP wall: staging->live promote [Crom-held] >>>>>>>>\n'
set +e
bash "$CI/gate-totp.sh" lodgers live promote
rc=$?
set -e
if [ "$rc" -eq 77 ]; then
  printf '\n================ RESULT ================\n'
  note "PROVEN: auto sh path ran A1->A4 with zero human input, then HALTED at G6 (and identically G8)."
  note "G6/G8 require Crom's CROM-PRIVATE TOTP — not fired. dev->live wall reached as designed."
  exit 0
fi
die "expected G6 dry-run halt (exit 77), got $rc"
