#!/usr/bin/env bash
# Disposable end-to-end acceptance for additive and populated migration routes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EVIDENCE=${TIER0_MIGRATION_ACCEPTANCE_ROOT:-${RUNNER_TEMP:-/tmp}/tier0-migration-acceptance}
case "$EVIDENCE" in
  "${RUNNER_TEMP:-/tmp}"/migration-acceptance|"${RUNNER_TEMP:-/tmp}"/tier0-migration-acceptance) ;;
  *) echo "refusing unsafe migration acceptance root: $EVIDENCE" >&2; exit 64 ;;
esac
rm -rf "$EVIDENCE"
mkdir -p "$EVIDENCE"

export TIER0_POSTGRES_IMAGE=${TIER0_POSTGRES_IMAGE:?digest-pinned PostgreSQL image required}
export TIER0_APP_BOOT_COMMAND="python3 '$ROOT/fixture/probe-server.py'"
export TIER0_APP_PROBE_URL=http://127.0.0.1:18081/tier0/database-probe
export TIER0_APP_PROBE_ATTEMPTS=10

cat > "$EVIDENCE/additive-route.json" <<'JSON'
{"outcome":"PENDING_ADDITIVE_EMPTY","affectedTables":["Additive"],"candidateMigrations":["20260101_Additive"]}
JSON
cat > "$EVIDENCE/additive.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS "__EFMigrationsHistory" ("MigrationId" varchar(150) PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "Additive" (id integer PRIMARY KEY, optional text NULL);
INSERT INTO "__EFMigrationsHistory" VALUES ('20260101_Additive') ON CONFLICT DO NOTHING;
SQL
GITHUB_RUN_ID=${GITHUB_RUN_ID:-1001} "$ROOT/postgres-validation.sh" \
  --route "$EVIDENCE/additive-route.json" --candidate-script "$EVIDENCE/additive.sql" \
  --evidence "$EVIDENCE/additive-evidence.json"
jq -e '.outcome == "PASSED_ADDITIVE_EMPTY" and .databaseHealth.status == "healthy" and
  .databaseHealth.insertReadBack == true and .databaseHealth.rolledBack == true' \
  "$EVIDENCE/additive-evidence.json" >/dev/null

cat > "$EVIDENCE/risky-route.json" <<'JSON'
{"outcome":"PENDING_POPULATED_UPGRADE","affectedTables":["Existing"],"candidateMigrations":["20260102_Risky"]}
JSON
cat > "$EVIDENCE/baseline.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS "__EFMigrationsHistory" ("MigrationId" varchar(150) PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "Existing" (id integer PRIMARY KEY, value text NOT NULL);
INSERT INTO "__EFMigrationsHistory" VALUES ('20260101_Baseline') ON CONFLICT DO NOTHING;
SQL
cat > "$EVIDENCE/risky.sql" <<'SQL'
ALTER TABLE "Existing" ADD COLUMN IF NOT EXISTS optional text NULL;
INSERT INTO "__EFMigrationsHistory" VALUES ('20260102_Risky') ON CONFLICT DO NOTHING;
SQL
# Expansion is intentionally deferred to postgres-validation.sh's isolated fixture shell.
# shellcheck disable=SC2016
export TIER0_FIXTURE_COMMAND='container=$(docker ps --filter label=tier0.disposable=true --format "{{.Names}}");
test -n "$container";
docker exec "$container" psql -v ON_ERROR_STOP=1 -U tier0 -d tier0 -c "INSERT INTO \"Existing\" (id, value) VALUES (1, '\''preserve-me'\'')"'
GITHUB_RUN_ID=$((${GITHUB_RUN_ID:-1001} + 1)) "$ROOT/postgres-validation.sh" \
  --route "$EVIDENCE/risky-route.json" --candidate-script "$EVIDENCE/risky.sql" \
  --baseline-script "$EVIDENCE/baseline.sql" --evidence "$EVIDENCE/risky-evidence.json"
jq -e '.outcome == "PASSED_POPULATED_UPGRADE" and (.affectedTables | length) == 1 and
  .affectedTables[0].table == "Existing" and .affectedTables[0].rows == 1 and
  (.affectedTables[0].dataSha256 | length) == 32 and
  .databaseHealth.appliedMigrationCount == 2 and .databaseHealth.rolledBack == true' \
  "$EVIDENCE/risky-evidence.json" >/dev/null

# A populated route can never fall back to the additive path when fixture
# generation fails. It must stop before candidate application and clean Docker.
export TIER0_FIXTURE_COMMAND=false
if GITHUB_RUN_ID=$((${GITHUB_RUN_ID:-1001} + 2)) "$ROOT/postgres-validation.sh" \
  --route "$EVIDENCE/risky-route.json" --candidate-script "$EVIDENCE/risky.sql" \
  --baseline-script "$EVIDENCE/baseline.sql" --evidence "$EVIDENCE/fixture-failure-evidence.json"; then
  echo "fixture-generation failure unexpectedly passed" >&2
  exit 1
fi
test -z "$(docker ps -aq --filter label=tier0.disposable=true)"
printf 'disposable PostgreSQL additive and populated acceptance passed\n'
