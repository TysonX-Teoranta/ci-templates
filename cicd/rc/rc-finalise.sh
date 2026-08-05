#!/usr/bin/env bash
# rc-finalise.sh — RC finalisation: cut a live-ready, versioned BUILT ARTIFACT from a
# domain's dev branch (artifact model — staging/live never build; they only receive).
#
# Policy (Crom, 2026-07-04):
#   - Scrub model: marked DEV-ONLY blocks are stripped from the build workspace before
#     publish; the repo hygiene battery must then prove nothing marked survived (IL scan).
#   - ZERO stubs to staging: any stub marker in shipped source refuses the RC.
#   - Hard fails, no override: unmarked hack patterns, config incompleteness, log posture
#     (Console.*, NLog Trace/Debug on shipped sinks, unmarked dev-noise logs).
#   - No commit-backs: the scrub mutates the CI workspace only; dev history is untouched.
#
# The repo owns its domain-specific hygiene battery via ONE entrypoint contract:
#   .github/scripts/ci/rc-hygiene.sh <scrub|source|publish>
#     scrub   — strip DEV-ONLY blocks in-place in the workspace
#     source  — post-scrub source checks (hacks/stubs/config/logs); non-zero = refuse RC
#     publish — checks against $PUBLISH_DIR (IL scan, dev-config absence); non-zero = refuse
# A domain with `hygiene: required` in domains.yml MUST ship that entrypoint or the cut dies.
#
# Env in : DOMAIN (required) · BUMP rc|patch|minor|major (default rc) · DRY_RUN 0|1
#          RID override · GH_TOKEN (tag push + release create)
# Out    : GITHUB_OUTPUT rc_tag/version/artifact; prerelease vX.Y.Z-rc.N with
#          <domain>-<tag>-<rid>.tar.gz + manifest.json + sha256sums.txt
set -uo pipefail

# shellcheck source=../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

DOMAIN="${DOMAIN:?DOMAIN is required}"
BUMP="${BUMP:-rc}"
DRY_RUN="${DRY_RUN:-0}"
WORKROOT="${GITHUB_WORKSPACE:-$PWD}"

case "$BUMP" in rc|patch|minor|major) ;; *) die "invalid BUMP '$BUMP' (rc|patch|minor|major)" 2 ;; esac
for t in git jq tar sha256sum dotnet gh; do require "$t"; done

# --- Registry ----------------------------------------------------------------
STATUS="$(domain_field "$DOMAIN" status)"
[ "$STATUS" = "active" ] || die "domain '$DOMAIN' is not active in domains.yml (status: ${STATUS:-unset}) — RC lane refused" 2
SOLUTION="$(domain_field "$DOMAIN" solution)"
APP_PROJECT="$(domain_field "$DOMAIN" app_project)"
DEV_BASE="$(domain_field "$DOMAIN" dev_base)"
TEST_PROJECT="$(domain_field "$DOMAIN" test_project)"
HYGIENE="$(domain_field "$DOMAIN" hygiene)"
RID="${RID:-$(domain_field "$DOMAIN" rid)}"; RID="${RID:-linux-x64}"
[ -n "$APP_PROJECT" ] || die "domain '$DOMAIN' has no app_project — artifact lane is dotnet-only" 2
DEV_BRANCH="${DEV_BASE#origin/}"
[ -n "$DEV_BRANCH" ] || die "domain '$DOMAIN' has no dev_base in domains.yml" 2

cd "$WORKROOT" || die "cannot cd to workspace $WORKROOT" 3

# --- ONE CANDIDATE AT A TIME (Crom, 2026-07-05) --------------------------------
# At most one open prerelease candidate per repo. A real cut while one is open is
# refused structurally — drop or supersede first (cicd rc <domain> drop|supersede).
if [ "$DRY_RUN" != "1" ]; then
  OPEN_RC="$(gh release list --limit 30 --json tagName,isPrerelease \
    --jq '[.[] | select(.isPrerelease) | .tagName][0] // empty' 2>/dev/null)"
  [ -n "$OPEN_RC" ] && die "candidate $OPEN_RC is already open — ONE candidate at a time; drop or supersede it first (cicd rc $DOMAIN drop|supersede)" 2
fi

# --- Branch guard: RCs finalise from the dev branch head, nothing else --------
HEAD_SHA="$(git rev-parse HEAD)"
DEV_TREE_SHA="$(git rev-parse 'HEAD^{tree}')"
DEV_SHA="$(git rev-parse "origin/$DEV_BRANCH" 2>/dev/null || true)"
[ -n "$DEV_SHA" ] || die "cannot resolve origin/$DEV_BRANCH — need a full-history checkout" 3
[ "$HEAD_SHA" = "$DEV_SHA" ] || die "HEAD ($HEAD_SHA) is not origin/$DEV_BRANCH head ($DEV_SHA) — refuse to cut" 2

# --- Hygiene contract ---------------------------------------------------------
HYG=".github/scripts/ci/rc-hygiene.sh"
if [ "$HYGIENE" = "required" ]; then
  [ -x "$HYG" ] || [ -f "$HYG" ] || die "hygiene is 'required' for $DOMAIN but $HYG is missing — refuse to cut" 2
fi
run_hygiene() { # $1 = mode
  if [ -f "$HYG" ]; then
    log "hygiene: $1"
    DOMAIN="$DOMAIN" PUBLISH_DIR="${PUBLISH_DIR:-}" bash "$HYG" "$1" || die "hygiene '$1' refused the RC (live-ready policy)" 1
  else
    warn "no $HYG — hygiene '$1' skipped (domain does not declare hygiene: required)"
  fi
}

# --- Version calc: vX.Y.Z-rc.N lineage ----------------------------------------
LATEST="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*-rc.[0-9]*' | sort -V | tail -1)"
if [ -z "$LATEST" ]; then
  BASE="0.1.0"; N=1
else
  BASE="${LATEST#v}"; BASE="${BASE%-rc.*}"
  N="${LATEST##*-rc.}"
  case "$BUMP" in
    rc) N=$((N + 1)) ;;
    *)  IFS=. read -r MA MI PA <<<"$BASE"
        case "$BUMP" in
          patch) PA=$((PA + 1)) ;;
          minor) MI=$((MI + 1)); PA=0 ;;
          major) MA=$((MA + 1)); MI=0; PA=0 ;;
        esac
        BASE="$MA.$MI.$PA"; N=1 ;;
  esac
fi
VERSION="$BASE-rc.$N"; TAG="v$VERSION"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists" 2
log "finalising $DOMAIN $TAG from $DEV_BRANCH@$HEAD_SHA (bump=$BUMP)"

# --- Snapshot dev-head onto the RC branch; the clean is COMMITTED here ----------
# Locked model (Crom, 2026-07-26): the RC is a separate, cleaned git version off
# dev-head — not a bare tag on dev, and not an ephemeral workspace scrub. Create the
# short-lived rc/<domain> branch at the dev-head SHA, run the deterministic scrub, and
# commit it as a machine-authored snapshot commit (parent = dev-head). Dev is untouched
# and keeps moving; the tag + build come off THIS cleaned commit.
RC_BRANCH="rc/$DOMAIN"
GIT_ID=(-c user.email="188377399+lodgings-ie@users.noreply.github.com" -c user.name="rc-finalise (spine)")
git checkout -q -B "$RC_BRANCH" "$HEAD_SHA" || die "cannot create RC branch $RC_BRANCH at $HEAD_SHA" 3

run_hygiene scrub
if git diff --quiet; then
  log "scrub: no DEV-ONLY content to strip — snapshot == dev-head"
  RC_COMMIT_SHA="$HEAD_SHA"
else
  git "${GIT_ID[@]}" commit -qam "RC scrub $TAG — strip DEV-ONLY (machine; snapshot of $DEV_BRANCH@$HEAD_SHA)" \
    || die "scrub commit failed" 1
  RC_COMMIT_SHA="$(git rev-parse HEAD)"
  log "scrub committed on $RC_BRANCH: $RC_COMMIT_SHA (parent $HEAD_SHA)"
fi
RC_TREE_SHA="$(git rev-parse 'HEAD^{tree}')"
SOURCE_EVIDENCE="${RUNNER_TEMP:-/tmp}/tier0-rc-source-evidence-${GITHUB_RUN_ID:-$$}.json"
python3 "$CICD_ROOT/lib/source-evidence.py" capture \
  --repo "$WORKROOT" --allow-untracked .ci-templates --output "$SOURCE_EVIDENCE" \
  || die "cannot capture immutable RC source identity" 1
run_hygiene source

# --- Central gate: secret scan over the source tree (zero-AI gitleaks) ----------
GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gates"
log "central gate: secret scan (source tree)"
TARGET="$WORKROOT" bash "$GATES_DIR/rc-gate-secrets.sh" \
  || die "secret-scan gate refused the RC (source)" 1

# --- Build, test, publish (Release; the RC is what live would get) -------------
[ -n "$SOLUTION" ] || SOLUTION="$APP_PROJECT"
log "restore + build (Release): $SOLUTION"
dotnet restore "$SOLUTION" || die "restore failed" 1
dotnet build "$SOLUTION" --no-restore -c Release || die "build failed (post-scrub source must compile)" 1

# --- Central gate: dependency vulnerabilities (zero-AI SDK advisory lookup) -----
# Restore graph now exists. Per-domain floor from the repo's rc.conf (RC_VULN_FLOOR,
# default High), read in a subshell so it does not pollute this script's namespace.
GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gates"
# shellcheck disable=SC1091
DEP_FLOOR="$( ( [ -r .github/scripts/ci/rc.conf ] && . .github/scripts/ci/rc.conf; printf '%s' "${RC_VULN_FLOOR:-High}" ) )"
log "central gate: dependency vulnerabilities (floor $DEP_FLOOR)"
PROJECT="$SOLUTION" RC_VULN_FLOOR="$DEP_FLOOR" bash "$GATES_DIR/rc-gate-dep-vuln.sh" \
  || die "dependency-vulnerability gate refused the RC" 1

# Licence compliance runs LATER (post-SBOM): it reads the CycloneDX SBOM instead of the
# nuget-license CLI (which core-dumps on this runner). See the licence gate after SBOM-gen.

if [ -n "$TEST_PROJECT" ]; then
  log "tests: $TEST_PROJECT"
  dotnet test "$TEST_PROJECT" -c Release || die "tests failed — RC refused" 1
else
  warn "no test_project for $DOMAIN — tests skipped at cut (gated per-PR only)"
fi
python3 "$CICD_ROOT/lib/source-evidence.py" verify \
  --repo "$WORKROOT" --allow-untracked .ci-templates --evidence "$SOURCE_EVIDENCE" \
  || die "RC source identity changed during build/test" 1

PUBLISH_DIR="$WORKROOT/rc-publish-out"
rm -rf "$PUBLISH_DIR"
log "publish: $APP_PROJECT -r $RID (framework-dependent)"
dotnet publish "$APP_PROJECT" -c Release -r "$RID" --self-contained false -o "$PUBLISH_DIR" \
  || die "publish failed" 1
# Universal never-ship files; repo hygiene 'publish' then verifies the full policy.
rm -rf "$PUBLISH_DIR/runtimes/win"* "$PUBLISH_DIR/runtimes/osx"* 2>/dev/null || true
rm -f "$PUBLISH_DIR/appsettings.Development.json"
export PUBLISH_DIR
run_hygiene publish

# --- Central gate: secret scan over the built artifact (zero-AI gitleaks) -------
log "central gate: secret scan (publish artifact)"
TARGET="$PUBLISH_DIR" bash "$GATES_DIR/rc-gate-secrets.sh" \
  || die "secret-scan gate refused the RC (publish)" 1

# --- Central gate: DI-wiring proof — cut-time smoke boot (zero-AI) ---------------
# Locked (Crom, 2026-07-28): boot the ACTUAL publish output on loopback with a neutral
# throwaway environment; an HTTP answer proves the host built (= DI graph resolved).
# Per-domain knobs (probe path / expected code / timeout) come from the repo rc.conf.
# shellcheck disable=SC1091  # rc.conf lives in the CALLING repo, resolved at run time
SMOKE_KNOBS="$( ( [ -r .github/scripts/ci/rc.conf ] && . .github/scripts/ci/rc.conf; \
  printf '%s|%s|%s' "${RC_SMOKE_PATH:-/}" "${RC_SMOKE_EXPECT:-any}" "${RC_SMOKE_TIMEOUT:-90}" ) )"
IFS='|' read -r SMOKE_PATH SMOKE_EXPECT SMOKE_TIMEOUT <<<"$SMOKE_KNOBS"
APP_DLL="$(basename "$APP_PROJECT")"; APP_DLL="${APP_DLL%.*}.dll"
log "central gate: smoke boot (DI wiring proof: $APP_DLL, probe $SMOKE_PATH expect $SMOKE_EXPECT)"
PUBLISH_DIR="$PUBLISH_DIR" APP_DLL="$APP_DLL" \
  RC_SMOKE_PATH="$SMOKE_PATH" RC_SMOKE_EXPECT="$SMOKE_EXPECT" RC_SMOKE_TIMEOUT="$SMOKE_TIMEOUT" \
  bash "$GATES_DIR/rc-gate-smoke.sh" \
  || die "smoke-boot gate refused the RC (DI wiring failed to prove)" 1

# --- Package: tarball + manifest + checksums -----------------------------------
STAGE_DIR="$WORKROOT/rc-artifact"
rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"
ARTIFACT="$DOMAIN-$TAG-$RID.tar.gz"
tar -C "$PUBLISH_DIR" -czf "$STAGE_DIR/$ARTIFACT" .
ART_SHA="$(sha256sum "$STAGE_DIR/$ARTIFACT" | awk '{print $1}')"
DOTNET_SDK="$(dotnet --version 2>/dev/null || echo unknown)"

# --- EF migrations script: schema ships WITH the artifact -----------------------
# Staging/live receive built artifacts (no SDK, no source) — the RC carries its schema
# as an IDEMPOTENT SQL script cut here from the same source SHA (arch-independent;
# ef's self-contained bundles cannot cross-cut x64 from the arm64 runner). Domains
# declare db_project (+ optional db_context) in domains.yml; domains without one skip
# the leg. The staging receiver rehearses the script on a probe CLONE of the staging
# DB before any acceptance, then applies it for real via psql as the app role.
DB_PROJECT="$(domain_field "$DOMAIN" db_project)"
DB_CONTEXT="$(domain_field "$DOMAIN" db_context)"
MIGSCRIPT="" MIG_SHA=""
if [ -n "$DB_PROJECT" ]; then
  log "migrations script (idempotent): $DB_PROJECT${DB_CONTEXT:+ (context $DB_CONTEXT)}"
  EFTOOL="$WORKROOT/.eftool"
  [ -x "$EFTOOL/dotnet-ef" ] || dotnet tool install dotnet-ef --tool-path "$EFTOOL" >/dev/null \
    || die "dotnet-ef install failed" 1
  MIGSCRIPT="$DOMAIN-$TAG-migrations.sql"
  "$EFTOOL/dotnet-ef" migrations script --idempotent \
    --project "$DB_PROJECT" --startup-project "$APP_PROJECT" \
    --configuration Release \
    ${DB_CONTEXT:+--context "$DB_CONTEXT"} \
    --output "$STAGE_DIR/$MIGSCRIPT" \
    || die "migrations script failed — RC refused (the schema must ship with the artifact)" 1
  MIG_SHA="$(sha256sum "$STAGE_DIR/$MIGSCRIPT" | awk '{print $1}')"
fi

# --- SBOM (CycloneDX): full dependency bill-of-materials ships with the RC ------
# ZERO AI: CycloneDX walks the restored dependency graph deterministically. Staging
# (= live) must always know exactly what shipped. Fail-closed: no SBOM, no RC.
SBOM="$DOMAIN-$TAG-sbom.json"; SBOM_SHA=""
CDXTOOL="$WORKROOT/.cdxtool"
[ -x "$CDXTOOL/dotnet-CycloneDX" ] || dotnet tool install CycloneDX --tool-path "$CDXTOOL" >/dev/null \
  || die "CycloneDX install failed" 1
log "SBOM (CycloneDX): $SOLUTION"
# SBOM from APP_PROJECT (what SHIPS) — not the solution, which drags in test-only deps
# (xunit etc.) that never enter the artifact. This is both a truer bill-of-materials and
# scopes the licence gate to shipped dependencies only.
"$CDXTOOL/dotnet-CycloneDX" "$APP_PROJECT" --output "$STAGE_DIR" --filename "$SBOM" --json \
  || die "SBOM generation failed — RC refused (staging must know exactly what ships)" 1
[ -s "$STAGE_DIR/$SBOM" ] || die "SBOM empty — RC refused" 1
SBOM_SHA="$(sha256sum "$STAGE_DIR/$SBOM" | awk '{print $1}')"
log "SBOM: $SBOM ($SBOM_SHA)"

# --- Central gate: dependency licence compliance (zero-AI; reads the SBOM) ------
# Reuses the CycloneDX SBOM just generated (no separate licence tool — nuget-license
# core-dumps on the runner). Per-domain allowlist via rc.conf RC_LICENSE_ALLOW.
# shellcheck disable=SC1091
LIC_ALLOW="$( ( [ -r .github/scripts/ci/rc.conf ] && . .github/scripts/ci/rc.conf; printf '%s' "${RC_LICENSE_ALLOW:-}" ) )"
log "central gate: licence compliance (from SBOM)"
SBOM_FILE="$STAGE_DIR/$SBOM" RC_LICENSE_ALLOW="$LIC_ALLOW" bash "$GATES_DIR/rc-gate-license.sh" \
  || die "licence-compliance gate refused the RC" 1

# Provenance records the full lineage: dev-head SHA (the snapshot's parent) + the cleaned
# RC commit SHA (what actually built + ships) + the RC branch + tag.
jq -n \
  --arg domain "$DOMAIN" --arg tag "$TAG" --arg version "$VERSION" \
  --arg sha "$HEAD_SHA" --arg branch "$DEV_BRANCH" --arg rid "$RID" \
  --arg devtree "$DEV_TREE_SHA" --arg rccommit "$RC_COMMIT_SHA" \
  --arg rctree "$RC_TREE_SHA" --arg rcbranch "$RC_BRANCH" \
  --arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sdk "$DOTNET_SDK" \
  --arg artifact "$ARTIFACT" --arg asha "$ART_SHA" \
  --arg mig "$MIGSCRIPT" --arg migsha "$MIG_SHA" \
  --arg sbom "$SBOM" --arg sbomsha "$SBOM_SHA" \
  '{schema: 3, domain: $domain, tag: $tag, version: $version,
    dev_head_sha: $sha, dev_tree_sha: $devtree,
    rc_commit_sha: $rccommit, rc_tree_sha: $rctree, rc_branch: $rcbranch,
    source_sha: $rccommit, source_tree_sha: $rctree, source_branch: $branch,
    tested_source_sha: $rccommit, tested_tree_sha: $rctree,
    artifact_provenance_source_sha: $rccommit,
    migrations_provenance_source_sha: $rccommit,
    rid: $rid, built_utc: $built, dotnet_sdk: $sdk,
    artifact: $artifact, artifact_sha256: $asha,
    migrations_script: $mig, migrations_sha256: $migsha,
    sbom: $sbom, sbom_sha256: $sbomsha,
    stubs: "none (zero-stub policy)", hygiene: "passed"}' > "$STAGE_DIR/manifest.json"
( cd "$STAGE_DIR" && sha256sum "$ARTIFACT" manifest.json ${MIGSCRIPT:+"$MIGSCRIPT"} ${SBOM:+"$SBOM"} > sha256sums.txt )
log "artifact: $ARTIFACT ($ART_SHA)${MIGSCRIPT:+ + $MIGSCRIPT ($MIG_SHA)}"

python3 "$CICD_ROOT/lib/source-evidence.py" capture \
  --repo "$WORKROOT" --allow-untracked .ci-templates \
  --allow-untracked rc-publish-out --allow-untracked rc-artifact \
  --allow-untracked .eftool --allow-untracked .cdxtool \
  --artifact "$STAGE_DIR/$ARTIFACT" --output "$SOURCE_EVIDENCE" \
  || die "cannot bind RC artifact to immutable source" 1
python3 "$CICD_ROOT/lib/source-evidence.py" verify \
  --repo "$WORKROOT" --allow-untracked .ci-templates \
  --allow-untracked rc-publish-out --allow-untracked rc-artifact \
  --allow-untracked .eftool --allow-untracked .cdxtool \
  --artifact "$STAGE_DIR/$ARTIFACT" --evidence "$SOURCE_EVIDENCE" \
  || die "RC artifact provenance verification failed" 1

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "rc_tag=$TAG"; echo "version=$VERSION"; echo "artifact=$ARTIFACT"; } >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "## RC finalised: $DOMAIN $TAG"
    echo '```json'; cat "$STAGE_DIR/manifest.json"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — artifact built + hygiene proven; NO tag, NO release. Done."
  exit 0
fi

# --- Push the cleaned snapshot branch + tag + prerelease ----------------------
# The tag points at the CLEANED RC commit (not dev-head). rc/<domain> is the persistent
# cleaned RC version, decoupled from dev; --force-with-lease tolerates a lingering branch
# from a prior candidate (drop frees the slot via the prerelease; the branch is reused/reset).
git tag -a "$TAG" -m "RC $TAG — cleaned snapshot of $DEV_BRANCH@$HEAD_SHA (rc commit $RC_COMMIT_SHA)" "$RC_COMMIT_SHA" \
  || die "tag create failed" 1
git push origin "refs/heads/$RC_BRANCH" --force-with-lease || die "RC branch push failed" 1
git push origin "refs/tags/$TAG" || die "tag push failed" 1
NOTES="$STAGE_DIR/notes.md"
{ echo "RC \`$TAG\` for **$DOMAIN** — live-ready by construction (scrubbed, zero-stub, hygiene-proven)."
  echo; echo '```json'; cat "$STAGE_DIR/manifest.json"; echo '```'
  echo; echo "Promote: \`cicd promote $DOMAIN staging\` (TOTP gate)."; } > "$NOTES"
gh release create "$TAG" --prerelease \
  --title "$DOMAIN $TAG (RC artifact)" --notes-file "$NOTES" \
  "$STAGE_DIR/$ARTIFACT" "$STAGE_DIR/manifest.json" "$STAGE_DIR/sha256sums.txt" \
  ${MIGSCRIPT:+"$STAGE_DIR/$MIGSCRIPT"} \
  ${SBOM:+"$STAGE_DIR/$SBOM"} \
  || die "release create failed" 1
log "RC finalised: $TAG (prerelease + artifact published)"
