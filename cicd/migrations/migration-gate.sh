#!/usr/bin/env bash
# Orchestrates exact-source migration classification and disposable PostgreSQL proof.
set -euo pipefail
ROOT=${GITHUB_WORKSPACE:-$PWD}
CONFIG=${TIER0_MIGRATION_CONFIG:-$ROOT/.tier0/migrations/baseline.json}
DECLARATIONS=${TIER0_MIGRATION_DECLARATIONS:-$ROOT/.tier0/migrations/declarations}
EVIDENCE_DIR=${TIER0_MIGRATION_EVIDENCE_DIR:-${RUNNER_TEMP:-/tmp}/tier0-migration-evidence}
SPINE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BASELINE_WORKTREE=""

cleanup() {
  if [ -n "$BASELINE_WORKTREE" ] && [ -d "$BASELINE_WORKTREE" ]; then
    git -C "$ROOT" worktree remove --force "$BASELINE_WORKTREE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for tool in git jq python3 dotnet sha256sum; do command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 69; }; done
[ -f "$CONFIG" ] || { echo "migration baseline config missing; fail closed: $CONFIG" >&2; exit 78; }
test -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all -- ':!.ci-templates')" \
  || { echo "source checkout is not immutable" >&2; exit 1; }
SOURCE_SHA=$(git -C "$ROOT" rev-parse 'HEAD^{commit}')
TREE_SHA=$(git -C "$ROOT" rev-parse 'HEAD^{tree}')
BASELINE_SHA=$(jq -r '.sourceSha // empty' "$CONFIG")
PREVIOUS_MIGRATION=$(jq -r '.previousMigration // empty' "$CONFIG")
DB_PROJECT=$(jq -r '.dbProject' "$CONFIG")
STARTUP_PROJECT=$(jq -r '.startupProject' "$CONFIG")
MIGRATION_ASSEMBLY=$(jq -r '.migrationAssembly' "$CONFIG")
DB_CONTEXT=$(jq -r '.dbContext // empty' "$CONFIG")
mkdir -p "$EVIDENCE_DIR"

dotnet build "$ROOT/$STARTUP_PROJECT" -c Release
dotnet build "$SPINE/migrations/Tier0.MigrationInspector/Tier0.MigrationInspector.csproj" -c Release
dotnet run --project "$SPINE/migrations/Tier0.MigrationInspector/Tier0.MigrationInspector.csproj" \
  -c Release --no-build -- --assembly "$ROOT/$MIGRATION_ASSEMBLY" \
  --output "$EVIDENCE_DIR/inspection.json"

CONTRACT_ARGS=(--inspection "$EVIDENCE_DIR/inspection.json" --declarations "$DECLARATIONS"
  --previous-migration "$PREVIOUS_MIGRATION" --output "$EVIDENCE_DIR/route.json")
if [ "$(jq -r '.populatedBaselineEstablished // false' "$CONFIG")" = true ]; then
  CONTRACT_ARGS+=(--baseline-source-sha "$BASELINE_SHA")
fi
python3 "$SPINE/migrations/migration-contract.py" "${CONTRACT_ARGS[@]}"
OUTCOME=$(jq -r '.outcome' "$EVIDENCE_DIR/route.json")
if [ "$OUTCOME" = NOT_REQUIRED ]; then
  jq --arg source "$SOURCE_SHA" --arg tree "$TREE_SHA" \
    '. + {sourceSha:$source, treeSha:$tree, outcome:"NOT_REQUIRED"}' \
    "$EVIDENCE_DIR/route.json" > "$EVIDENCE_DIR/evidence.json"
  exit 0
fi
if [ "$OUTCOME" = QUARANTINED_NO_BASELINE ]; then
  cp "$EVIDENCE_DIR/route.json" "$EVIDENCE_DIR/evidence.json"
  exit 78
fi

EFTOOL="$EVIDENCE_DIR/eftool"
dotnet tool install dotnet-ef --tool-path "$EFTOOL" >/dev/null
CONTEXT_ARGS=()
[ -n "$DB_CONTEXT" ] && CONTEXT_ARGS=(--context "$DB_CONTEXT")
"$EFTOOL/dotnet-ef" migrations script --idempotent \
  --project "$ROOT/$DB_PROJECT" --startup-project "$ROOT/$STARTUP_PROJECT" \
  --configuration Release "${CONTEXT_ARGS[@]}" --output "$EVIDENCE_DIR/candidate.sql"
while IFS= read -r migration_id; do
  grep -Fq "$migration_id" "$EVIDENCE_DIR/candidate.sql" \
    || { echo "generated script does not contain classified migration $migration_id; fail closed" >&2; exit 1; }
done < <(jq -r '.candidateMigrations[]' "$EVIDENCE_DIR/route.json")

BASELINE_ARGS=()
if [ "$OUTCOME" = PENDING_POPULATED_UPGRADE ]; then
  [ -n "$BASELINE_SHA" ] || exit 78
  BASELINE_WORKTREE=$(mktemp -d "${RUNNER_TEMP:-/tmp}/tier0-baseline.XXXXXX")
  git -C "$ROOT" worktree add --detach "$BASELINE_WORKTREE" "$BASELINE_SHA" >/dev/null
  dotnet restore "$BASELINE_WORKTREE/$STARTUP_PROJECT"
  "$EFTOOL/dotnet-ef" migrations script --idempotent \
    --project "$BASELINE_WORKTREE/$DB_PROJECT" --startup-project "$BASELINE_WORKTREE/$STARTUP_PROJECT" \
    --configuration Release "${CONTEXT_ARGS[@]}" --output "$EVIDENCE_DIR/baseline.sql"
  BASELINE_ARGS=(--baseline-script "$EVIDENCE_DIR/baseline.sql")
fi

PUBLISH="$EVIDENCE_DIR/publish"
dotnet publish "$ROOT/$STARTUP_PROJECT" -c Release -o "$PUBLISH" \
  /p:Tier0SourceSha="$SOURCE_SHA" /p:Tier0BuildId="migration-${GITHUB_RUN_ID:-local}" \
  /p:Tier0BuiltAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export TIER0_POSTGRES_IMAGE
TIER0_POSTGRES_IMAGE=$(jq -r '.postgresImage' "$CONFIG")
export TIER0_FIXTURE_COMMAND
TIER0_FIXTURE_COMMAND=$(jq -r '.fixtureCommand // empty' "$CONFIG")
export TIER0_APP_BOOT_COMMAND
TIER0_APP_BOOT_COMMAND=$(jq -r --arg publish "$PUBLISH" '.appBootCommand | gsub("%PUBLISH%"; $publish)' "$CONFIG")
export TIER0_APP_PROBE_URL
TIER0_APP_PROBE_URL=$(jq -r '.appProbeUrl' "$CONFIG")
"$SPINE/migrations/postgres-validation.sh" --route "$EVIDENCE_DIR/route.json" \
  --candidate-script "$EVIDENCE_DIR/candidate.sql" "${BASELINE_ARGS[@]}" \
  --evidence "$EVIDENCE_DIR/evidence.json"

jq --arg source "$SOURCE_SHA" --arg tree "$TREE_SHA" \
  '. + {sourceSha:$source, treeSha:$tree}' "$EVIDENCE_DIR/evidence.json" \
  > "$EVIDENCE_DIR/evidence.bound.json"
mv "$EVIDENCE_DIR/evidence.bound.json" "$EVIDENCE_DIR/evidence.json"
