#!/usr/bin/env bash
# Destructive fault-injection battery. Never give a primary runner the exact
# `tier0-disposable` label or set the disposable marker on it.
set -euo pipefail

CICD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WATCHDOG="$CICD_ROOT/lib/test-watchdog.sh"
FIXTURE="$CICD_ROOT/watchdog/scenario-fixture.sh"
REAL_FIXTURE="$CICD_ROOT/watchdog/real-fixture.sh"
CLEANUP_FIXTURE="$CICD_ROOT/watchdog/cleanup-fixture.sh"
RETRY_FIXTURE="$CICD_ROOT/watchdog/retry-fixture.sh"
RETRY_WATCHDOG="$CICD_ROOT/lib/test-watchdog-retry.sh"
WEDGED_DUMP="$CICD_ROOT/watchdog/wedged-dump.sh"
[ "${TIER0_DISPOSABLE_RUNNER:-}" = 1 ] || { echo "refusing: TIER0_DISPOSABLE_RUNNER=1 required" >&2; exit 77; }
case ",${RUNNER_LABELS:-}," in *,tier0-disposable,*) ;; *) echo "refusing: tier0-disposable label required" >&2; exit 77 ;; esac
[ "${DEPLOYMENT_CREDENTIALS_PRESENT:-0}" = 0 ] || { echo "refusing: deployment credentials present" >&2; exit 77; }
[ "${PRIMARY_RUNNER:-1}" = 0 ] || { echo "refusing: PRIMARY_RUNNER must be explicitly 0" >&2; exit 77; }
[ "$(id -u)" -eq 0 ] || { echo "refusing: isolated battery must run as root" >&2; exit 77; }

if [ -n "${TIER0_ACCEPTANCE_ROOT:-}" ]; then
  WORK="$TIER0_ACCEPTANCE_ROOT"
  mkdir -p "$WORK"
else
  WORK=$(mktemp -d /tmp/tier0-watchdog-acceptance.XXXXXXXX)
  trap 'rm -rf -- "$WORK"' EXIT
fi
PASS=0 FAIL=0
FIXTURE_BIN="$CICD_ROOT/watchdog/fixture/bin"
TIER0_FIXTURE_HASH=$(find "$FIXTURE_BIN" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
export TIER0_FIXTURE_HASH
record() { if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi; }
no_scope_processes() { ! systemctl list-units 'tier0-test-*' --state=running --no-legend | grep -q .; }
clean_followup() {
  local d="$1/followup"
  mkdir -p "$d"
  export TIER0_FIXTURE_ROOT="$d"
  "$WATCHDOG" --heartbeat "$d/hb" --phase-file "$d/phase" \
    --coverage "$d/coverage.xml" --diagnostics "$d/diag" --test-deadline 20 \
    --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 8 \
    --dump-deadline 2 --cleanup-hook "$CLEANUP_FIXTURE" -- "$REAL_FIXTURE" "$d" success
}
run_real_fault() {
  local name="$1" expected="$2"; shift 2
  local d="$WORK/$name" rc
  mkdir -p "$d"
  export TIER0_FIXTURE_ROOT="$d"
  set +e
  "$WATCHDOG" --heartbeat "$d/hb" --phase-file "$d/phase" \
    --coverage "$d/coverage.xml" --diagnostics "$d/diag" --cleanup-hook "$CLEANUP_FIXTURE" \
    "$@" -- "$REAL_FIXTURE" "$d" "$name"
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] && no_scope_processes && clean_followup "$d"
}
run_dump_wedge() {
  local d="$WORK/dump_collector_wedge" rc dump_pid
  mkdir -p "$d"
  export TIER0_DUMP_PID_FILE="$d/dump.pid"
  set +e
  "$WATCHDOG" --heartbeat "$d/hb" --phase-file "$d/phase" --coverage "$d/coverage.xml" \
    --diagnostics "$d/diag" --test-deadline 20 --coverage-deadline 20 \
    --coverage-processing-deadline 20 --progress-deadline 3 --dump-deadline 2 \
    --dump-command "$WEDGED_DUMP" -- "$FIXTURE" "$d" testhost_unresponsive
  rc=$?
  set -e
  dump_pid=$(cat "$d/dump.pid")
  [ "$rc" -eq 75 ] && ! kill -0 "$dump_pid" 2>/dev/null && no_scope_processes && clean_followup "$d"
}
run_retry_contract() {
  local mode="$1" expected="$2" attempts="$3" d="$WORK/retry_$1" rc
  mkdir -p "$d"
  set +e
  "$RETRY_WATCHDOG" --heartbeat "$d/hb" --phase-file "$d/phase" \
    --coverage "$d/coverage.xml" --diagnostics "$d/diag" --test-deadline 20 \
    --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 3 \
    --dump-deadline 2 -- "$RETRY_FIXTURE" "$d" "$mode"
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] && [ "$(cat "$d/$mode.count")" -eq "$attempts" ] && no_scope_processes
}
run_fault() {
  local name="$1" expected="$2"; shift 2
  local d="$WORK/$name" rc
  mkdir -p "$d"
  set +e
  "$WATCHDOG" --heartbeat "$d/hb" --phase-file "$d/phase" \
    --coverage "$d/coverage.xml" --diagnostics "$d/diag" "$@" -- "$FIXTURE" "$d" "$name"
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] && no_scope_processes && clean_followup "$d"
}

record run_fault testhost_unresponsive 75 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 3 --dump-deadline 2
record run_fault coverlet_wedge 75 --test-deadline 20 --coverage-deadline 3 --coverage-processing-deadline 20 --progress-deadline 10 --dump-deadline 2
record run_fault orphan_child 0 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 8 --dump-deadline 2
record run_fault hard_deadline 75 --test-deadline 3 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 10 --dump-deadline 2
record run_fault missing_cancel 75 --test-deadline 3 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 10 --dump-deadline 2
record run_fault partial_coverage 1 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 8 --dump-deadline 2
record run_fault long_valid_test 0 --test-deadline 8 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 4 --dump-deadline 2
record run_fault long_valid_coverage 0 --test-deadline 20 --coverage-deadline 8 --coverage-processing-deadline 20 --progress-deadline 4 --dump-deadline 2
record run_fault quiet_with_heartbeat 0 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 4 --dump-deadline 2
record run_real_fault real_testhost_unresponsive 75 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 5 --dump-deadline 2
record run_real_fault real_coverlet_wedge 75 --test-deadline 20 --coverage-deadline 5 --coverage-processing-deadline 20 --progress-deadline 10 --dump-deadline 2
record run_dump_wedge
record run_retry_contract infrastructure 0 2
record run_retry_contract assertion 42 1

printf 'watchdog isolated acceptance: passed=%d failed=%d evidence=%s\n' "$PASS" "$FAIL" "$WORK"
[ "$FAIL" -eq 0 ]
