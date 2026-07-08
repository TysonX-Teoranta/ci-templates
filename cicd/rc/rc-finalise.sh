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

# --- Scrub + source hygiene (workspace only — never committed) -----------------
run_hygiene scrub
run_hygiene source

# --- Build, test, publish (Release; the RC is what live would get) -------------
[ -n "$SOLUTION" ] || SOLUTION="$APP_PROJECT"
log "restore + build (Release): $SOLUTION"
dotnet restore "$SOLUTION" || die "restore failed" 1
dotnet build "$SOLUTION" --no-restore -c Release || die "build failed (post-scrub source must compile)" 1
if [ -n "$TEST_PROJECT" ]; then
  log "tests: $TEST_PROJECT"
  dotnet test "$TEST_PROJECT" -c Release || die "tests failed — RC refused" 1
else
  warn "no test_project for $DOMAIN — tests skipped at cut (gated per-PR only)"
fi

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

# --- Package: tarball + manifest + checksums -----------------------------------
STAGE_DIR="$WORKROOT/rc-artifact"
rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"
ARTIFACT="$DOMAIN-$TAG-$RID.tar.gz"
tar -C "$PUBLISH_DIR" -czf "$STAGE_DIR/$ARTIFACT" .
ART_SHA="$(sha256sum "$STAGE_DIR/$ARTIFACT" | awk '{print $1}')"
DOTNET_SDK="$(dotnet --version 2>/dev/null || echo unknown)"

# --- EF migrations bundle: schema ships WITH the artifact -----------------------
# Staging/live receive built artifacts (no SDK, no source) — the only live-grade way
# to apply the RC's schema is a self-contained migrations bundle cut here, from the
# same source SHA. Domains declare db_project (+ optional db_context) in domains.yml;
# domains without one skip the leg. The staging receiver rehearses the bundle on a
# probe CLONE of the staging DB before any acceptance, then applies it for real.
DB_PROJECT="$(domain_field "$DOMAIN" db_project)"
DB_CONTEXT="$(domain_field "$DOMAIN" db_context)"
MIGBUNDLE="" MIG_SHA=""
if [ -n "$DB_PROJECT" ]; then
  log "migrations bundle: $DB_PROJECT${DB_CONTEXT:+ (context $DB_CONTEXT)}"
  EFTOOL="$WORKROOT/.eftool"
  [ -x "$EFTOOL/dotnet-ef" ] || dotnet tool install dotnet-ef --tool-path "$EFTOOL" >/dev/null \
    || die "dotnet-ef install failed" 1
  MIGBUNDLE="$DOMAIN-$TAG-efbundle"
  "$EFTOOL/dotnet-ef" migrations bundle \
    --project "$DB_PROJECT" --startup-project "$APP_PROJECT" \
    --configuration Release --runtime "$RID" --self-contained \
    ${DB_CONTEXT:+--context "$DB_CONTEXT"} \
    --output "$STAGE_DIR/$MIGBUNDLE" --force \
    || die "migrations bundle failed — RC refused (the schema must ship with the artifact)" 1
  MIG_SHA="$(sha256sum "$STAGE_DIR/$MIGBUNDLE" | awk '{print $1}')"
fi

jq -n \
  --arg domain "$DOMAIN" --arg tag "$TAG" --arg version "$VERSION" \
  --arg sha "$HEAD_SHA" --arg branch "$DEV_BRANCH" --arg rid "$RID" \
  --arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sdk "$DOTNET_SDK" \
  --arg artifact "$ARTIFACT" --arg asha "$ART_SHA" \
  --arg mig "$MIGBUNDLE" --arg migsha "$MIG_SHA" \
  '{schema: 1, domain: $domain, tag: $tag, version: $version, source_sha: $sha,
    source_branch: $branch, rid: $rid, built_utc: $built, dotnet_sdk: $sdk,
    artifact: $artifact, artifact_sha256: $asha,
    migrations_bundle: $mig, migrations_sha256: $migsha,
    stubs: "none (zero-stub policy)", hygiene: "passed"}' > "$STAGE_DIR/manifest.json"
( cd "$STAGE_DIR" && sha256sum "$ARTIFACT" manifest.json ${MIGBUNDLE:+"$MIGBUNDLE"} > sha256sums.txt )
log "artifact: $ARTIFACT ($ART_SHA)${MIGBUNDLE:+ + $MIGBUNDLE ($MIG_SHA)}"

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

# --- Tag + prerelease (provenance record; the release asset IS what ships) ----
git tag -a "$TAG" -m "RC $TAG — live-ready artifact cut from $DEV_BRANCH@$HEAD_SHA" "$HEAD_SHA" \
  || die "tag create failed" 1
git push origin "refs/tags/$TAG" || die "tag push failed" 1
NOTES="$STAGE_DIR/notes.md"
{ echo "RC \`$TAG\` for **$DOMAIN** — live-ready by construction (scrubbed, zero-stub, hygiene-proven)."
  echo; echo '```json'; cat "$STAGE_DIR/manifest.json"; echo '```'
  echo; echo "Promote: \`cicd promote $DOMAIN staging\` (TOTP gate)."; } > "$NOTES"
gh release create "$TAG" --prerelease \
  --title "$DOMAIN $TAG (RC artifact)" --notes-file "$NOTES" \
  "$STAGE_DIR/$ARTIFACT" "$STAGE_DIR/manifest.json" "$STAGE_DIR/sha256sums.txt" \
  ${MIGBUNDLE:+"$STAGE_DIR/$MIGBUNDLE"} \
  || die "release create failed" 1
log "RC finalised: $TAG (prerelease + artifact published)"
