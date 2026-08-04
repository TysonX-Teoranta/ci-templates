#!/usr/bin/env bash
set -euo pipefail
HB="$1/hb" PHASE="$1/phase" COVERAGE="$1/coverage.xml" SCENARIO="${2:-success}"
coverage() { printf '<coverage><packages><package><classes><class name="Fixture"><lines><line number="1" hits="1"/></lines></class></classes></package></packages></coverage>\n' > "$COVERAGE"; }
beat_for() { local seconds="$1"; for _ in $(seq 1 "$seconds"); do touch "$HB"; sleep 1; done; }
case "$SCENARIO" in
  success) beat_for 1; coverage ;;
  testhost_unresponsive) sleep 30 ;;
  coverlet_wedge) printf 'coverage\n' > "$PHASE"; touch "$HB"; sleep 30 ;;
  orphan_child) sleep 30 & coverage ;;
  hard_deadline) while :; do touch "$HB"; sleep 1; done ;;
  partial_coverage) printf '<coverage><packages>' > "$COVERAGE" ;;
  long_valid_test) beat_for 6; coverage ;;
  long_valid_coverage) printf 'coverage\n' > "$PHASE"; beat_for 6; coverage ;;
  quiet_with_heartbeat) beat_for 6; coverage ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
