#!/usr/bin/env bash
set -euo pipefail
ROOT="$1" SCENARIO="${2:-success}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT="$HERE/fixture/Tier0.Watchdog.Fixture.csproj"
RESULTS="$ROOT/TestResults"
mkdir -p "$RESULTS"

run_test() {
  dotnet test "$PROJECT" --no-restore -c Release --results-directory "$RESULTS" \
    --collect 'XPlat Code Coverage' "$@"
}
copy_coverage() {
  local report
  report=$(find "$RESULTS" -name coverage.cobertura.xml -type f -print -quit)
  [ -n "$report" ]
  cp "$report" "$ROOT/coverage.xml"
}

case "$SCENARIO" in
  success)
    run_test
    copy_coverage
    ;;
  real_testhost_unresponsive)
    TIER0_REAL_HANG=1 run_test --filter RealTesthostCanBeMadeUnresponsive
    ;;
  real_coverlet_wedge)
    run_test --filter CleanFollowupPasses
    copy_coverage
    printf 'coverage\n' > "$ROOT/phase"
    touch "$ROOT/hb"
    sleep 30
    ;;
  *)
    echo "unknown real fixture scenario: $SCENARIO" >&2
    exit 2
    ;;
esac
