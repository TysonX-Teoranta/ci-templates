#!/usr/bin/env bash
set -euo pipefail
ROOT="${TIER0_FIXTURE_ROOT:?}"
BASELINE="${TIER0_FIXTURE_HASH:?}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dotnet build "$HERE/fixture/Tier0.Watchdog.Fixture.csproj" -c Release --no-restore >/dev/null
CURRENT=$(find "$HERE/fixture/bin" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
printf 'baseline=%s\ncurrent=%s\n' "$BASELINE" "$CURRENT" > "$ROOT/instrumentation-hashes.txt"
[ "$CURRENT" = "$BASELINE" ]
find "$ROOT/TestResults" -mindepth 1 -delete 2>/dev/null || true
