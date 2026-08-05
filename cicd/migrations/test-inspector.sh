#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${TMPDIR:-/tmp}/tier0-migration-inspector-$$.json
trap 'rm -f "$OUT"' EXIT

dotnet build "$ROOT/fixture/Tier0.MigrationFixture.csproj" -c Release
dotnet build "$ROOT/Tier0.MigrationInspector/Tier0.MigrationInspector.csproj" -c Release
dotnet run --project "$ROOT/Tier0.MigrationInspector/Tier0.MigrationInspector.csproj" \
  -c Release --no-build -- \
  --assembly "$ROOT/fixture/bin/Release/net10.0/Tier0.MigrationFixture.dll" --output "$OUT"

python3 - "$OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
by_id = {item["migration"].split("_", 1)[1]: item for item in data["migrations"]}
assert by_id["CreateAndNullable"]["classification"] == "pure-additive"
assert by_id["RiskyKnown"]["classification"] == "data-sensitive"
assert by_id["UnknownDefaultsRisky"]["classification"] == "data-sensitive"
assert any(op["type"] == "SqlOperation" and not op["additive"]
           for op in by_id["RiskyKnown"]["operations"])
print("migration inspector acceptance: pass")
PY
