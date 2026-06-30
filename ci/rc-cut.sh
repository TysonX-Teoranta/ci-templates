#!/usr/bin/env bash
# ci/rc-cut.sh — GATE A1: cut a Release Candidate on the dev branch.
#
# Driver = sh (zero human, no confirm-phrase). On any failure the RC tag is NOT created and the
# step fails loudly (block + fail-report). Steps:
#   1. version  : compute the next v<X.Y.Z>-rc.<N> tag from existing tags + the bump.
#   2. build    : restore + build(Release) + test(unit/integration)  [native; CI_SKIP_BUILD=1 to skip in a local proof]
#   3. hygiene  : audit-native-libs.sh + detect-hacks.sh + rc-gate.sh scrub-verify staging
#   4. commit   : commit any scrubbed DEV-ONLY content back to the dev branch
#   5. tag      : tag + push the RC
#
# Env (from the thin YAML caller):
#   SOLUTION, WEB_PROJECT, DEV_BRANCH, DOMAIN, BUMP, RUN_HYGIENE(default true), CI_SKIP_BUILD(default 0)
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Per-domain RC config (KB_GATE etc.) — see ci/rc.conf. The ONLY intended spine divergence besides
# rc-forbidden.txt; sourced after lib.sh so CI_DIR is set. Absent -> the defaults below apply.
[ -r "$CI_DIR/rc.conf" ] && . "$CI_DIR/rc.conf"
KB_GATE="${KB_GATE:-0}"

SOLUTION="${SOLUTION:?SOLUTION required}"
DEV_BRANCH="${DEV_BRANCH:?DEV_BRANCH required}"
DOMAIN="${DOMAIN:?DOMAIN required}"
BUMP="${BUMP:-patch}"
RUN_HYGIENE="${RUN_HYGIENE:-true}"
CI_SKIP_BUILD="${CI_SKIP_BUILD:-0}"

# _rc_next <version> — next rc number for v<version>: (max existing rc.N) + 1.
# Deterministic POSIX numeric scan, independent of git versionsort suffix handling;
# tolerant of a missing plain v<version> release tag and of zero existing rc tags (-> 1).
_rc_next() {
  _v=$1; _max=0
  for _t in $(git tag -l "v${_v}-rc.*"); do
    _n=${_t##*-rc.}
    case $_n in ''|*[!0-9]*) continue ;; esac
    [ "$_n" -gt "$_max" ] && _max=$_n
  done
  echo $((_max + 1))
}

cd "$REPO_ROOT"

stage "A1.1 — compute RC version (bump=$BUMP)"
# Tolerant of an empty tag set (fresh repo): pipefail must not kill us when grep finds nothing.
LATEST_TAG=$( { git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | grep -v - || true; } | head -1)
[ -z "$LATEST_TAG" ] && LATEST_TAG="v0.0.0"
CURRENT=${LATEST_TAG#v}; IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
MAJOR=${MAJOR:-0}; MINOR=${MINOR:-0}; PATCH=${PATCH:-0}
case "$BUMP" in
  major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR+1)); PATCH=0 ;;
  patch) PATCH=$((PATCH+1)) ;;
  *) die "unknown bump '$BUMP' (want patch|minor|major)" ;;
esac
NEXT_VERSION="${MAJOR}.${MINOR}.${PATCH}"
NEXT_RC=$(_rc_next "$NEXT_VERSION")
RC_TAG="v${NEXT_VERSION}-rc.${NEXT_RC}"
set_out RC_TAG "$RC_TAG"
log "RC_TAG=$RC_TAG (from $LATEST_TAG)"

if [ "$CI_SKIP_BUILD" = "1" ]; then
  stage "A1.2 — build+test (SKIPPED: CI_SKIP_BUILD=1, native CI step)"
else
  stage "A1.2 — restore + build(Release) + test (unit/integration; e2e relocated to A3 soak)"
  # Bounded MSBuild parallelism (-maxcpucount:2 == -m:2): the dev RC build OOMs (MSB4166 / node
  # crash, box swapping) under fleet contention at full fan-out. Cap to 2 MSBuild nodes so the cut
  # never swaps the box. If a project still OOMs, add -p:BuildInParallel=false to this build line.
  dotnet restore "$SOLUTION"
  dotnet build "$SOLUTION" --configuration Release --no-restore -maxcpucount:2
  # The Playwright e2e suite is EXCLUDED from the A1 rc-cut and RELOCATED to the A3 staging-soak,
  # where it runs against the deployed staging site (see deploy-staging.yml). Running it inside the
  # cut spun an ephemeral app on the shared dev box and a slow page (LI_ENQ_018 /homeowner/
  # applications PBKDF2 decrypt hang, ~120-200s) stalled/OOM'd the cut. The filter below is the same
  # one ci-pr.yml and ci-staging-live.yml already use; it is a no-op on domains with no E2E category
  # / Playwright project (kukuln/tysonx), so this spine stays byte-identical across all three copies.
  # Bound worker parallelism so the remaining unit/integration tests never saturate the box:
  #   NUnit.NumberOfTestWorkers=2  -> at most 2 parallel test workers (not =cores -> no OOM).
  #   NUnit.DefaultTimeout=90000   -> per-test 90s cap; a stuck test fails itself and frees a worker.
  #   RunConfiguration.TestSessionTimeout=1800000 -> per-suite 30m backstop for the whole test pass.
  #   --blame-hang-timeout/-dump   -> catastrophic backstop: mini-dump + kill if a test goes silent 8m.
  dotnet test  "$SOLUTION" --configuration Release --no-build --verbosity normal \
    --filter "Category!=E2E&FullyQualifiedName!~LodgersSite.Playwright" \
    --blame-hang-timeout 8m --blame-hang-dump-type mini \
    -- NUnit.NumberOfTestWorkers=2 NUnit.DefaultTimeout=90000 RunConfiguration.TestSessionTimeout=1800000
fi

if [ "$RUN_HYGIENE" = "true" ]; then
  stage "A1.3 — hygiene: native-lib audit + dev-only scan + RC scrub/verify (governance gate)"
  WEB_PROJECT="${WEB_PROJECT:-}" bash "$SCRIPTS_DIR/audit-native-libs.sh"
  stage "A1.3c — Check20: config completeness (staging required keys present + consistent)"
  bash "$CI_DIR/check-config-complete.sh" Staging .
  bash "$SCRIPTS_DIR/detect-hacks.sh"
  stage "A1.3a — Check18: dev-only logs MARKED (unmarked shipping-level dev-noise fails)"
  bash "$CI_DIR/check-logdev.sh" .
  stage "A1.3d — Check15: zero Console.* in app source (bootstrap logs route via NLog)"
  bash "$CI_DIR/check-no-console.sh" .
  stage "A1.3e — Check11: Dev* DI guards fail-closed on !IsDevelopment() (staging + production)"
  bash "$CI_DIR/check-di-failclosed.sh" .
  bash "$SCRIPTS_DIR/rc-gate.sh" scrub-verify staging .
  stage "A1.3e - publish-based RC gates (build-once artifact: Check3 provenance / Check12 IL fake-scan / Check14 parity-clean)"
  bash "$CI_DIR/rc-publish-gates.sh"
  stage "A1.3b — Check19: NLog minlevel>=Info on live/shipped sinks (parity-live, no Trace/Debug live)"
  bash "$CI_DIR/check-nlog-minlevel.sh" .
else
  stage "A1.3 — hygiene (SKIPPED: RUN_HYGIENE=false)"
fi

if [ "$KB_GATE" = "1" ]; then
  stage "A1.3b — KB bundle + blocking gate (C178197393523617)"
  # Package the KB loader+content into the RC (manifest is tracked so promote can re-verify;
  # the .tgz is regenerable and gitignored) then HARD-gate on a sane, non-empty, drift-free KB.
  # A bad/empty/drifted KB fails the cut HERE, before A1.5 ever tags the RC. Domain-gated by
  # KB_GATE (ci/rc.conf): only the tysonx KB pipeline sets it; a no-op for lodgers/kukuln.
  bash "$CI_DIR/kb-bundle.sh"
  bash "$CI_DIR/kb-gate.sh"
fi

stage "A1.4 — commit scrubbed RC content (if any)"
git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
if git diff --quiet; then
  log "no scrubbed changes to commit."
else
  # Commit is a remote-bound mutation of the dev branch — gate it so a dry run never writes a
  # commit onto the working branch. In CI (DRY_RUN=0) it runs for real (scrub output only).
  run_or_echo "git add -A"
  run_or_echo "git commit -m 'chore: scrub DEV-ONLY blocks for $RC_TAG (DIR-085)'"
  pushed=0
  for _t in 1 2 3 4 5; do
    run_or_echo "git fetch origin $DEV_BRANCH && git rebase origin/$DEV_BRANCH" || run_or_echo "git rebase --abort" || true
    if run_or_echo "git push origin HEAD:$DEV_BRANCH"; then pushed=1; break; fi
    [ "$DRY_RUN" = "1" ] && { pushed=1; break; }
    sleep 3
  done
  [ "$pushed" = "1" ] || die "failed to push scrubbed content"
fi

# C178173122910335: per-RC SEED SNAPSHOT (opt-in via SEED_SNAPSHOT=true; OFF by default so other
# spine consumers are unaffected). Seed a CLEAN THROWAWAY DB to SEED_N users through the EXISTING
# seed machinery (seed-and-snapshot.sh: Staging + SEED_ON_DEPLOY + SeedOptions:SampleUsers — NO new
# entrypoint, NO Development flip) and pg_dump -Fc into seed-snapshot/<RC_TAG>.dump. Runs AFTER the
# scrub commit (so the dump is never staged into the dev branch) and BEFORE the tag, so a seed
# failure aborts the script and NO RC tag is created. The _create-rc YAML uploads the dump as the
# seed-snapshot-<RC_TAG> artifact; promote-to-staging carries it; deploy-staging pg_restores it.
if [ "${SEED_SNAPSHOT:-false}" = "true" ]; then
  stage "A1.4b — per-RC SEED SNAPSHOT (seed throwaway DB to N=${SEED_N:-?} users, pg_dump -Fc)"
  : "${SEED_N:?SEED_N required when SEED_SNAPSHOT=true}"
  : "${PG_ADMIN_CONN:?PG_ADMIN_CONN required when SEED_SNAPSHOT=true}"
  : "${SEED_SAMPLE_PASSWORD:?SEED_SAMPLE_PASSWORD required when SEED_SNAPSHOT=true}"
  : "${SEED_ADMIN_PASSWORD:?SEED_ADMIN_PASSWORD required when SEED_SNAPSHOT=true}"
  mkdir -p "$REPO_ROOT/seed-snapshot"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: would seed N=$SEED_N + snapshot $RC_TAG -> seed-snapshot/$RC_TAG.dump"
  else
    SEED_N="$SEED_N" \
    PG_ADMIN_CONN="$PG_ADMIN_CONN" \
    SEED_SAMPLE_PASSWORD="$SEED_SAMPLE_PASSWORD" \
    SEED_ADMIN_PASSWORD="$SEED_ADMIN_PASSWORD" \
    SNAPSHOT_OUT="$REPO_ROOT/seed-snapshot/${RC_TAG}.dump" \
    MANIFEST_OUT="$REPO_ROOT/seed-snapshot/${RC_TAG}.manifest.json" \
    THROWAWAY_DB="rc_seed_${GITHUB_RUN_ID:-$$}" \
    APP_PROJECT="${WEB_PROJECT:-LodgersSite/LodgersSite.csproj}" \
      bash "$SCRIPTS_DIR/seed-and-snapshot.sh"
  fi
fi

stage "A1.5 — tag release candidate $RC_TAG"
# The tag itself is a LOCAL git op (cheap, reversible) so the spine proves it even in a dry run
# and the next stage (A2) can find it; only the PUSH reaches the remote and is gated.
if git rev-parse -q --verify "refs/tags/$RC_TAG" >/dev/null 2>&1; then
  log "tag $RC_TAG already present locally."
else
  git tag -a "$RC_TAG" -m "Release candidate $RC_TAG"
fi
run_or_echo "git push origin '$RC_TAG'"
note "A1 OK — RC cut: $RC_TAG"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "## Tagged: \`$RC_TAG\`" >> "$GITHUB_STEP_SUMMARY" || true
