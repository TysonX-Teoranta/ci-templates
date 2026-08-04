#!/usr/bin/env bash
# Exactly one retry for watchdog-classified infrastructure failures. Assertion and
# cleanup failures are returned immediately and are never retried.
set -uo pipefail
WATCHDOG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-watchdog.sh
"$WATCHDOG" "$@"
status=$?
[ "$status" -eq 75 ] || exit "$status"
printf 'test-watchdog: infrastructure failure; starting sole retry\n' >&2
"$WATCHDOG" "$@"
