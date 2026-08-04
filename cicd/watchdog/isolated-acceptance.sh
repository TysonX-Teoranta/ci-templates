#!/usr/bin/env bash
# Destructive fault-injection battery. Never give a primary runner the exact
# `tier0-disposable` label or set the disposable marker on it.
set -euo pipefail

CICD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WATCHDOG="$CICD_ROOT/lib/test-watchdog.sh"
FIXTURE="$CICD_ROOT/watchdog/scenario-fixture.sh"
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
record() { if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi; }
no_scope_processes() { ! systemctl list-units 'tier0-test-*' --state=running --no-legend | grep -q .; }
clean_followup() {
  local d="$1/followup"
  mkdir -p "$d"
  SCENARIO=success "$WATCHDOG" --heartbeat "$d/hb" --phase-file "$d/phase" \
    --coverage "$d/coverage.xml" --diagnostics "$d/diag" --test-deadline 20 \
    --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 8 \
    --dump-deadline 2 -- "$FIXTURE" "$d"
}
run_fault() {
  local name="$1" expected="$2"; shift 2
  local d="$WORK/$name" rc
  mkdir -p "$d"
  set +e
  SCENARIO="$name" "$WATCHDOG" --heartbeat "$d/hb" --phase-file "$d/phase" \
    --coverage "$d/coverage.xml" --diagnostics "$d/diag" "$@" -- "$FIXTURE" "$d"
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] && no_scope_processes && clean_followup "$d"
}

record run_fault testhost_unresponsive 75 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 3 --dump-deadline 2
record run_fault coverlet_wedge 75 --test-deadline 20 --coverage-deadline 3 --coverage-processing-deadline 20 --progress-deadline 10 --dump-deadline 2
record run_fault orphan_child 0 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 8 --dump-deadline 2
record run_fault hard_deadline 75 --test-deadline 3 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 10 --dump-deadline 2
record run_fault partial_coverage 1 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 8 --dump-deadline 2
record run_fault long_valid_test 0 --test-deadline 8 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 4 --dump-deadline 2
record run_fault long_valid_coverage 0 --test-deadline 20 --coverage-deadline 8 --coverage-processing-deadline 20 --progress-deadline 4 --dump-deadline 2
record run_fault quiet_with_heartbeat 0 --test-deadline 20 --coverage-deadline 20 --coverage-processing-deadline 20 --progress-deadline 4 --dump-deadline 2

printf 'watchdog isolated acceptance: passed=%d failed=%d evidence=%s\n' "$PASS" "$FAIL" "$WORK"
[ "$FAIL" -eq 0 ]
