#!/usr/bin/env bash
# Deterministic disposable-PostgreSQL validation for a pre-classified migration route.
set -euo pipefail

usage() {
  echo "usage: postgres-validation.sh --route route.json --candidate-script candidate.sql --evidence evidence.json [--baseline-script baseline.sql]" >&2
  exit 64
}

ROUTE="" CANDIDATE="" BASELINE="" EVIDENCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --route) ROUTE="${2:-}"; shift 2 ;;
    --candidate-script) CANDIDATE="${2:-}"; shift 2 ;;
    --baseline-script) BASELINE="${2:-}"; shift 2 ;;
    --evidence) EVIDENCE="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
if [ ! -f "$ROUTE" ] || [ -z "$EVIDENCE" ]; then usage; fi
for tool in docker jq sha256sum curl openssl setsid python3; do command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 69; }; done

PENDING=$(jq -r '.outcome' "$ROUTE")
if [ "$PENDING" = NOT_REQUIRED ]; then
  jq '.outcome = "NOT_REQUIRED"' "$ROUTE" > "$EVIDENCE"
  exit 0
fi
if [ "$PENDING" = QUARANTINED_NO_BASELINE ]; then
  jq '.outcome = "QUARANTINED_NO_BASELINE"' "$ROUTE" > "$EVIDENCE"
  exit 78
fi
[ -s "$CANDIDATE" ] || { echo "candidate migration script is missing" >&2; exit 1; }

IMAGE="${TIER0_POSTGRES_IMAGE:?TIER0_POSTGRES_IMAGE must pin the supported PostgreSQL image}"
case "$IMAGE" in *@sha256:*) ;; *) echo "PostgreSQL image must be pinned by digest" >&2; exit 64 ;; esac
case "${GITHUB_RUN_ID:-$$}" in *[!0-9]*) echo "invalid run id" >&2; exit 64 ;; esac
CONTAINER="tier0-pg-${GITHUB_RUN_ID:-$$}-${RANDOM}"
PASSWORD=$(openssl rand -hex 24)
WORK=$(mktemp -d)
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ]; then
    kill -- "-$APP_PID" 2>/dev/null || kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  [ ! -f "$WORK/app.log" ] || cp "$WORK/app.log" "$EVIDENCE.app.log"
  [ ! -f "$WORK/probe.json" ] || cp "$WORK/probe.json" "$EVIDENCE.probe.json"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

docker run -d --name "$CONTAINER" --label tier0.disposable=true \
  -e POSTGRES_USER=tier0 -e POSTGRES_PASSWORD="$PASSWORD" -e POSTGRES_DB=tier0 \
  -p 127.0.0.1::5432 "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$CONTAINER" pg_isready -U tier0 -d tier0 >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$CONTAINER" pg_isready -U tier0 -d tier0 >/dev/null
PORT=$(docker port "$CONTAINER" 5432/tcp | sed -n 's/.*://p' | head -1)
case "$PORT" in ''|*[!0-9]*) echo "cannot resolve disposable PostgreSQL port" >&2; exit 1 ;; esac
export TIER0_DATABASE_CONNECTION="Host=127.0.0.1;Port=$PORT;Database=tier0;Username=tier0;Password=$PASSWORD;SSL Mode=Disable"

psql_file() {
  local file=$1 name
  name=$(basename "$file")
  docker cp "$file" "$CONTAINER:/tmp/$name" >/dev/null
  docker exec -e PGPASSWORD="$PASSWORD" "$CONTAINER" psql -v ON_ERROR_STOP=1 -U tier0 -d tier0 -f "/tmp/$name" >/dev/null
}

fingerprint() {
  local prefix=$1 table quoted
  docker exec -e PGPASSWORD="$PASSWORD" "$CONTAINER" pg_dump -U tier0 -d tier0 --schema-only --no-owner --no-privileges \
    | sha256sum | awk '{print $1}' > "$WORK/$prefix-schema.sha256"
  : > "$WORK/$prefix-tables.tsv"
  while IFS= read -r table; do
    case "$table" in ''|*[!A-Za-z0-9_.]*) echo "invalid affected table identifier: $table" >&2; exit 64 ;; esac
    quoted=$(printf '%s' "$table" | sed 's/\./"."/g')
    docker exec -e PGPASSWORD="$PASSWORD" "$CONTAINER" psql -At -U tier0 -d tier0 \
      -c "SELECT '$table', count(*), coalesce(md5(string_agg(t::text, E'\\n' ORDER BY t::text)), md5('')) FROM \"$quoted\" t" \
      >> "$WORK/$prefix-tables.tsv"
  done < <(jq -r '.affectedTables[]?' "$ROUTE")
}

if [ "$PENDING" = PENDING_POPULATED_UPGRADE ]; then
  [ -s "$BASELINE" ] || { echo "populated-upgrade route has no baseline script" >&2; exit 78; }
  [ -n "${TIER0_FIXTURE_COMMAND:-}" ] || { echo "fixture generation unavailable; quarantine" >&2; exit 78; }
  psql_file "$BASELINE"
  TIER0_DATABASE_CONNECTION="$TIER0_DATABASE_CONNECTION" bash -euo pipefail -c "$TIER0_FIXTURE_COMMAND"
  fingerprint pre
fi

psql_file "$CANDIDATE"
psql_file "$CANDIDATE"
fingerprint post

if [ "$PENDING" = PENDING_POPULATED_UPGRADE ]; then
  python3 - "$WORK/pre-tables.tsv" "$WORK/post-tables.tsv" <<'PY'
import sys
def counts(path):
    result = {}
    for line in open(path, encoding="utf-8"):
        name, count, _ = line.rstrip("\n").split("|", 2)
        result[name] = int(count)
    return result
before, after = counts(sys.argv[1]), counts(sys.argv[2])
if before != after:
    raise SystemExit(f"affected-table row counts changed: before={before}, after={after}")
PY
fi

[ -n "${TIER0_APP_BOOT_COMMAND:-}" ] || { echo "exact candidate boot command is missing" >&2; exit 1; }
[ -n "${TIER0_APP_PROBE_URL:-}" ] || { echo "candidate database probe URL is missing" >&2; exit 1; }
PROBE_TOKEN=$(openssl rand -hex 32)
export ConnectionStrings__DatabaseConnection="$TIER0_DATABASE_CONNECTION"
export Tier0__DatabaseProbeToken="$PROBE_TOKEN"
setsid bash -euo pipefail -c "$TIER0_APP_BOOT_COMMAND" >"$WORK/app.log" 2>&1 &
APP_PID=$!
PROBE_ATTEMPTS=${TIER0_APP_PROBE_ATTEMPTS:-90}
case "$PROBE_ATTEMPTS" in ''|*[!0-9]*) echo "invalid application probe attempt count" >&2; exit 64 ;; esac
[ "$PROBE_ATTEMPTS" -ge 1 ] && [ "$PROBE_ATTEMPTS" -le 90 ] \
  || { echo "application probe attempts must be between 1 and 90" >&2; exit 64; }
for _ in $(seq 1 "$PROBE_ATTEMPTS"); do
  kill -0 "$APP_PID" 2>/dev/null || { tail -80 "$WORK/app.log" >&2; exit 1; }
  if curl -fsS -X POST -H "X-Tier0-Probe-Token: $PROBE_TOKEN" "$TIER0_APP_PROBE_URL" > "$WORK/probe.json"; then break; fi
  sleep 2
done
jq -e '.status == "healthy" and .insertReadBack == true and .rolledBack == true' "$WORK/probe.json" >/dev/null

FINAL=PASSED_ADDITIVE_EMPTY
[ "$PENDING" = PENDING_POPULATED_UPGRADE ] && FINAL=PASSED_POPULATED_UPGRADE
jq -n --slurpfile route "$ROUTE" --slurpfile probe "$WORK/probe.json" \
  --arg outcome "$FINAL" --arg image "$IMAGE" \
  --arg script_sha "$(sha256sum "$CANDIDATE" | awk '{print $1}')" \
  --arg schema_sha "$(cat "$WORK/post-schema.sha256")" \
  --argjson rows "$(jq -Rn '[inputs | split("|") | {table:.[0], rows:(.[1]|tonumber), dataSha256:.[2]}]' < "$WORK/post-tables.tsv")" \
  '{schema:1, outcome:$outcome, postgresImage:$image, migrationScriptSha256:$script_sha,
    route:$route[0], postSchemaSha256:$schema_sha, affectedTables:$rows, databaseHealth:$probe[0]}' \
  > "$EVIDENCE"
