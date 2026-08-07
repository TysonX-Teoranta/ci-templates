#!/usr/bin/env bash
# rc-analyse.sh — post-cut RC analysis (Tier 2, REPORT-ONLY; Crom 2026-08-07).
# Runs AFTER the candidate is tagged and can never void, delay, or fail it:
#   1. coverage ratchet — re-measure line+branch on the exact cut tree with the
#      gate's coverlet-offline recipe and raise the committed high-water baseline
#      via an auto-merging PR (the ratchet never lowers);
#   2. scoped Stryker mutation — one bounded, sequential run per committed domain
#      config (cicd/mutation/*.json in the PRODUCT repo), each hard-capped.
# The nightly cron lane is retired: heavy analysis burns the single dev runner
# only when a human deliberately orders a candidate, and every report is bound
# to the exact RC source instead of whatever HEAD was at 06:00.
#
# Env in : DOMAIN (required) · EXPECTED_SHA (required) · EVIDENCE_DIR (required)
#          RC_TAG · DRY_RUN 0|1 · GH_TOKEN (ratchet PR + release upload)
#          COVERAGE_BASELINE (default .github/coverage-baseline.json)
#          MUTATION_CAP_MINUTES (default 60)
# Out    : $EVIDENCE_DIR/** — cobertura + per-domain mutation reports + summary.json
#          exit 0 whenever binding holds and coverage measured; mutation outcomes
#          are RECORDED, never fatal (report-only by construction).
set -uo pipefail

# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

DOMAIN="${DOMAIN:?DOMAIN is required}"
EXPECTED_SHA="${EXPECTED_SHA:?EXPECTED_SHA is required}"
EVIDENCE_DIR="${EVIDENCE_DIR:?EVIDENCE_DIR is required}"
RC_TAG="${RC_TAG:-}"
DRY_RUN="${DRY_RUN:-0}"
COVERAGE_BASELINE="${COVERAGE_BASELINE:-.github/coverage-baseline.json}"
MUTATION_CAP_MINUTES="${MUTATION_CAP_MINUTES:-60}"
WORKROOT="${GITHUB_WORKSPACE:-$PWD}"

for t in git jq dotnet; do require "$t"; done
mkdir -p "$EVIDENCE_DIR"

# --- Registry ------------------------------------------------------------------
TEST_PROJECT="$(domain_field "$DOMAIN" test_project)"
DEV_BASE="$(domain_field "$DOMAIN" dev_base)"
DEV_BRANCH="${DEV_BASE#origin/}"
[ -n "$TEST_PROJECT" ] || die "domain '$DOMAIN' has no test_project in domains.yml" 2
[ -n "$DEV_BRANCH" ] || die "domain '$DOMAIN' has no dev_base in domains.yml" 2

cd "$WORKROOT" || die "cannot cd to workspace $WORKROOT" 3

# --- Evidence binding: analyse the exact cut source, nothing else ---------------
HEAD_SHA="$(git rev-parse HEAD)"
TREE_SHA="$(git rev-parse 'HEAD^{tree}')"
[ "$HEAD_SHA" = "$EXPECTED_SHA" ] || die "HEAD ($HEAD_SHA) is not the cut source ($EXPECTED_SHA) — refuse to analyse the wrong build" 2

# --- Coverage re-measure: the gate's coverlet-offline recipe --------------------
# Offline instrumentation is profiler-free and emits line AND branch on arm64;
# dotnet-coverage's cobertura carries no branch data, so the ratchet could never
# raise the branch baseline off it.
export DOTNET_gcServer=0
dotnet tool install --global coverlet.console >/dev/null 2>&1 || true
export PATH="$PATH:$HOME/.dotnet/tools"
require coverlet
COVDIR="$EVIDENCE_DIR/coverage"
mkdir -p "$COVDIR"

log "building $TEST_PROJECT (Debug) for coverage re-measure on $HEAD_SHA"
dotnet build "$TEST_PROJECT" -c Debug || die "coverage build failed" 3

# Product-assembly include list — same derivation as the PR gate.
INCLUDES=""
while IFS= read -r name; do
  [ -n "$name" ] && INCLUDES="$INCLUDES --include [$name]*"
done < <(find . -name '*.csproj' -not -path '*/bin/*' -not -path '*/obj/*' \
  | grep -viE '/[^/]*tests?\.csproj$' \
  | while IFS= read -r proj; do
      name="$(sed -n 's:.*<AssemblyName>[[:space:]]*\([^<]*[^<[:space:]]\)[[:space:]]*</AssemblyName>.*:\1:p' "$proj" | head -1)"
      echo "${name:-$(basename "$proj" .csproj)}"
    done)
log "coverlet product includes:$INCLUDES"

run_coverlet_single() {
  local tbin tdir
  tbin="$(dirname "$TEST_PROJECT")/bin/Debug"
  [ -d "$tbin" ] || tbin="."
  tdir="$(find "$tbin" -maxdepth 1 -type d -name 'net*' | head -1)"
  [ -n "$tdir" ] || tdir="$tbin"
  # shellcheck disable=SC2086
  coverlet "$tdir" --target dotnet \
    --targetargs "test $TEST_PROJECT --no-build" \
    --format cobertura --output "$COVDIR/" \
    $INCLUDES
}

run_coverlet_solution() {
  # SOLUTION test_project: instrument each test project's own output dir and
  # accumulate through coverlet's json merge; the last leg also emits cobertura
  # so the ratchet sees one whole-suite report (cure from ci-templates#81).
  local first=1 tb td merge tproj
  while IFS= read -r tproj; do
    tb="$(dirname "$tproj")/bin/Debug"
    td="$(find "$tb" -maxdepth 1 -type d -name 'net*' 2>/dev/null | head -1)"
    [ -n "$td" ] || { warn "no build output for $tproj — skipped"; continue; }
    merge=""
    [ "$first" -eq 0 ] && merge="--merge-with $COVDIR/coverage.json"
    log "solution coverage: $tproj"
    # shellcheck disable=SC2086
    coverlet "$td" --target dotnet \
      --targetargs "test $tproj --no-build" \
      --format json --format cobertura --output "$COVDIR/" \
      $merge $INCLUDES || return 1
    first=0
  done < <(find . -name '*.csproj' -not -path '*/bin/*' -not -path '*/obj/*' \
    | grep -iE '/[^/]*tests?\.csproj$' | sort)
  [ "$first" -eq 0 ] || { err "no test projects with build output found in solution"; return 1; }
}

case "$TEST_PROJECT" in
  *.sln|*.slnx) run_coverlet_solution || die "solution coverage re-measure failed" 3 ;;
  *)            run_coverlet_single   || die "coverage re-measure failed" 3 ;;
esac

COBERTURA="$(find "$COVDIR" -name 'coverage.cobertura.xml' | head -1)"
[ -n "$COBERTURA" ] || die "coverage re-measure produced no cobertura report" 3

# --- Ratchet the baseline upward (auto-merging PR; dev branches are protected) --
RATCHET_BUMPED=0
FULLCOV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/full-coverage.sh"
bash "$FULLCOV" --cobertura "$COBERTURA" --baseline "$COVERAGE_BASELINE" --bump-baseline -v \
  || die "full-coverage ratchet evaluation failed" 3
if ! git diff --quiet -- "$COVERAGE_BASELINE"; then
  RATCHET_BUMPED=1
  BR="cicd/coverage-baseline-bump-${GITHUB_RUN_ID:-local}"
  git config user.name  lodgings-ie
  git config user.email 188377399+lodgings-ie@users.noreply.github.com
  git checkout -b "$BR"
  git add "$COVERAGE_BASELINE"
  git commit -m "cicd($DOMAIN): ratchet coverage baseline upward (RC analysis)"
  if git push origin "$BR" && gh pr create --base "$DEV_BRANCH" --head "$BR" \
      --title "cicd($DOMAIN): ratchet coverage baseline upward" \
      --body "Automated high-water bump from the RC-time re-measure of $HEAD_SHA. Auto-merges on green."; then
    log "ratchet bump PR opened from $BR"
  else
    warn "ratchet bump PR could not be opened — baseline raise recorded in evidence only"
    git push origin ":$BR" 2>/dev/null || true   # no orphan branch litter
  fi
  git checkout --detach "$HEAD_SHA" >/dev/null 2>&1 || true
else
  log "baseline unchanged — nothing to raise"
fi

# --- Scoped mutation: one bounded Stryker run per committed domain config -------
MUT_SUMMARY="[]"
shopt -s nullglob
CONFIGS=("$WORKROOT"/cicd/mutation/*.json)
shopt -u nullglob
if [ "${#CONFIGS[@]}" -eq 0 ]; then
  # No silent caps: say plainly that the mutation lane is not armed for this repo.
  note "no cicd/mutation/*.json committed — mutation lane not armed for $DOMAIN"
else
  require timeout
  TESTDIR="$WORKROOT/$(dirname "$TEST_PROJECT")"
  for cfg in "${CONFIGS[@]}"; do
    name="$(basename "$cfg" .json)"
    dest="$EVIDENCE_DIR/mutation/$name"
    mkdir -p "$dest"
    started="$(date -u +%s)"
    log "mutation[$name]: capped at ${MUTATION_CAP_MINUTES}m — $cfg"
    if (cd "$TESTDIR" && timeout "$((MUTATION_CAP_MINUTES * 60))" \
        dotnet stryker --config-file "$cfg" >"$dest/stryker.log" 2>&1); then
      outcome="completed"
    else
      rc=$?
      if [ "$rc" -eq 124 ]; then outcome="timeout-after-cap"; else outcome="failed-rc-$rc"; fi
    fi
    seconds=$(( $(date -u +%s) - started ))
    # Retain the reports, drop the bulky working dirs (clean as you go).
    find "$TESTDIR" -type d -name 'StrykerOutput' -prune -print0 2>/dev/null \
      | while IFS= read -r -d '' out; do
          find "$out" -type f \( -name 'mutation-report.*' -o -name '*.md' \) \
            -exec cp {} "$dest/" \; 2>/dev/null
          rm -rf "$out"
        done
    MUT_SUMMARY="$(jq -c --arg n "$name" --arg o "$outcome" --argjson s "$seconds" \
      '. + [{domain:$n, outcome:$o, seconds:$s}]' <<<"$MUT_SUMMARY")"
    log "mutation[$name]: $outcome after ${seconds}s"
  done
fi

# --- Summary bound to the exact cut source --------------------------------------
jq -n \
  --arg domain "$DOMAIN" \
  --arg rcTag "$RC_TAG" \
  --arg sourceSha "$HEAD_SHA" \
  --arg treeSha "$TREE_SHA" \
  --argjson ratchetBumped "$RATCHET_BUMPED" \
  --argjson mutation "$MUT_SUMMARY" \
  '{domain:$domain, rcTag:$rcTag, sourceSha:$sourceSha, treeSha:$treeSha,
    ratchetBumped:($ratchetBumped == 1), mutation:$mutation}' \
  > "$EVIDENCE_DIR/summary.json"
log "analysis summary: $(cat "$EVIDENCE_DIR/summary.json")"

# --- Attach the analysis to the candidate (real cuts only) -----------------------
if [ "$DRY_RUN" != "1" ] && [ -n "$RC_TAG" ] && have gh; then
  TARBALL="$(dirname "$EVIDENCE_DIR")/rc-analysis-$DOMAIN.tar.gz"
  tar -czf "$TARBALL" -C "$(dirname "$EVIDENCE_DIR")" "$(basename "$EVIDENCE_DIR")"
  if gh release upload "$RC_TAG" "$TARBALL" --clobber; then
    log "analysis attached to $RC_TAG"
  else
    warn "could not attach analysis to $RC_TAG — evidence retained as workflow artifact"
  fi
fi

exit 0
