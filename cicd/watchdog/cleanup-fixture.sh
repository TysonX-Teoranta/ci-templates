#!/usr/bin/env bash
set -euo pipefail
ROOT="${TIER0_FIXTURE_ROOT:?}"
BASELINE="${TIER0_FIXTURE_HASH:?}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CURRENT=$(find "$HERE/fixture/bin" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
[ "$CURRENT" = "$BASELINE" ]
find "$ROOT/TestResults" -mindepth 1 -delete 2>/dev/null || true
