#!/usr/bin/env bash
# test-watchdog.sh — deterministic systemd/cgroup supervisor for test coverage.
# Run as root through the narrowly scoped installed entry point; never install or
# fault-test this candidate on a primary runner before isolated acceptance passes.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: test-watchdog.sh --heartbeat FILE --phase-file FILE --coverage FILE
       --diagnostics DIR [--test-deadline 8100] [--coverage-deadline 1800]
       [--coverage-processing-deadline 600] [--progress-deadline 1500]
       [--dump-deadline 120] [--dump-command FILE] [--cleanup-hook FILE]
       [--cpu-quota 400%] [--memory-max 15G] -- COMMAND [ARG...]
EOF
  exit 2
}

HEARTBEAT="" PHASE_FILE="" COVERAGE_FILE="" DIAGNOSTICS="" CLEANUP_HOOK="" DUMP_COMMAND=""
CPU_QUOTA=400% MEMORY_MAX=15G
TEST_DEADLINE=8100 COVERAGE_DEADLINE=1800 COVERAGE_PROCESSING_DEADLINE=600
PROGRESS_DEADLINE=1500 DUMP_DEADLINE=120
while [ "$#" -gt 0 ]; do
  case "$1" in
    --heartbeat) HEARTBEAT="${2:-}"; shift 2 ;;
    --phase-file) PHASE_FILE="${2:-}"; shift 2 ;;
    --coverage) COVERAGE_FILE="${2:-}"; shift 2 ;;
    --diagnostics) DIAGNOSTICS="${2:-}"; shift 2 ;;
    --test-deadline) TEST_DEADLINE="${2:-}"; shift 2 ;;
    --coverage-deadline) COVERAGE_DEADLINE="${2:-}"; shift 2 ;;
    --coverage-processing-deadline) COVERAGE_PROCESSING_DEADLINE="${2:-}"; shift 2 ;;
    --progress-deadline) PROGRESS_DEADLINE="${2:-}"; shift 2 ;;
    --dump-deadline) DUMP_DEADLINE="${2:-}"; shift 2 ;;
    --dump-command) DUMP_COMMAND="${2:-}"; shift 2 ;;
    --cleanup-hook) CLEANUP_HOOK="${2:-}"; shift 2 ;;
    --cpu-quota) CPU_QUOTA="${2:-}"; shift 2 ;;
    --memory-max) MEMORY_MAX="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
if [ "$#" -eq 0 ] || [ -z "$HEARTBEAT" ] || [ -z "$PHASE_FILE" ] \
  || [ -z "$COVERAGE_FILE" ] || [ -z "$DIAGNOSTICS" ]; then
  usage
fi
for number in "$TEST_DEADLINE" "$COVERAGE_DEADLINE" "$COVERAGE_PROCESSING_DEADLINE" \
  "$PROGRESS_DEADLINE" "$DUMP_DEADLINE"; do
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || usage
done
[ "$(id -u)" -eq 0 ] || { echo "test-watchdog: root systemd manager access required" >&2; exit 77; }
command -v systemd-run >/dev/null || exit 77
command -v systemctl >/dev/null || exit 77
[[ "$CPU_QUOTA" =~ ^[1-9][0-9]*%$ ]] || usage
[[ "$MEMORY_MAX" =~ ^[1-9][0-9]*[KMG]$ ]] || usage

mkdir -p "$DIAGNOSTICS"
EVENTS="$DIAGNOSTICS/watchdog-events.tsv"
UNIT="tier0-test-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$$"
SERVICE="${UNIT}.service"
START=$(date +%s)
PHASE_START=$START
LAST_HEARTBEAT_MTIME=0
LAST_PROGRESS=$START
CURRENT_PHASE="test"
TERMINAL=0

event() { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >> "$EVENTS"; }
read_phase() {
  local value=test
  [ -s "$PHASE_FILE" ] && value=$(tr -d '\r\n' < "$PHASE_FILE")
  case "$value" in test|coverage|coverage-processing) printf '%s\n' "$value" ;; *) printf 'test\n' ;; esac
}
scope_empty() {
  [ "$(systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null || true)" = inactive ] \
    || [ "$(systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null || true)" = failed ]
}
kill_scope() {
  systemctl kill --kill-who=all --signal=SIGKILL "$SERVICE" >/dev/null 2>&1 || true
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do scope_empty && return 0; sleep 1; done
  return 1
}
collect_dump() {
  local leader dump_tool
  leader=$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)
  [[ "$leader" =~ ^[1-9][0-9]*$ ]] || return 0
  dump_tool="$DUMP_COMMAND"
  [ -n "$dump_tool" ] || dump_tool=$(command -v dotnet-dump || true)
  if [ -n "$dump_tool" ]; then
    timeout --kill-after=5 "$DUMP_DEADLINE" "$dump_tool" collect -p "$leader" \
      -o "$DIAGNOSTICS/hang.dmp" >> "$DIAGNOSTICS/dump.log" 2>&1 \
      || event dump_failed_or_timed_out "pid=$leader"
  else
    event dump_unavailable "pid=$leader"
  fi
}
cleanup_instrumentation() {
  if [ -n "$CLEANUP_HOOK" ]; then
    [ -x "$CLEANUP_HOOK" ] || { event cleanup_hook_invalid "$CLEANUP_HOOK"; return 1; }
    timeout --kill-after=5 120 "$CLEANUP_HOOK" >> "$DIAGNOSTICS/cleanup.log" 2>&1
  fi
}
finish_infrastructure_failure() {
  local reason="$1"
  event infrastructure_failure "$reason"
  collect_dump
  kill_scope || { event cleanup_failed "$SERVICE"; printf 'FAILED_CLEANUP\n' > "$DIAGNOSTICS/classification.txt"; exit 74; }
  cleanup_instrumentation || { printf 'FAILED_CLEANUP\n' > "$DIAGNOSTICS/classification.txt"; exit 74; }
  printf '%s\n' "$reason" > "$DIAGNOSTICS/classification.txt"
  TERMINAL=1
  exit 75
}
trap '[ "$TERMINAL" -eq 1 ] || kill_scope || true' EXIT INT TERM

touch "$HEARTBEAT"
printf 'test\n' > "$PHASE_FILE"
event start "service=$SERVICE"
systemd-run --unit="$UNIT" --collect --wait --service-type=exec --quiet \
  --property=KillMode=control-group --property=TimeoutStopSec=15s \
  --property="CPUQuota=$CPU_QUOTA" --property="MemoryMax=$MEMORY_MAX" -- "$@" &
LAUNCHER_PID=$!

while kill -0 "$LAUNCHER_PID" 2>/dev/null; do
  NOW=$(date +%s)
  NEW_PHASE=$(read_phase)
  if [ "$NEW_PHASE" != "$CURRENT_PHASE" ]; then
    CURRENT_PHASE="$NEW_PHASE"
    PHASE_START="$NOW"
    event phase "$CURRENT_PHASE"
  fi
  MTIME=$(stat -c %Y "$HEARTBEAT" 2>/dev/null || echo 0)
  if [ "$MTIME" != "$LAST_HEARTBEAT_MTIME" ]; then
    LAST_HEARTBEAT_MTIME=$MTIME LAST_PROGRESS=$NOW
  fi
  case "$CURRENT_PHASE" in
    test) PHASE_LIMIT=$TEST_DEADLINE ;;
    coverage) PHASE_LIMIT=$COVERAGE_DEADLINE ;;
    coverage-processing) PHASE_LIMIT=$COVERAGE_PROCESSING_DEADLINE ;;
  esac
  [ $((NOW - PHASE_START)) -lt "$PHASE_LIMIT" ] \
    || finish_infrastructure_failure "INFRASTRUCTURE_${CURRENT_PHASE^^}_DEADLINE"
  [ $((NOW - LAST_PROGRESS)) -lt "$PROGRESS_DEADLINE" ] \
    || finish_infrastructure_failure "INFRASTRUCTURE_${CURRENT_PHASE^^}_NO_PROGRESS"
  sleep 5
done

set +e
wait "$LAUNCHER_PID"
STATUS=$?
set -e
event process_exit "status=$STATUS"
cleanup_instrumentation || { printf 'FAILED_CLEANUP\n' > "$DIAGNOSTICS/classification.txt"; exit 74; }
[ "$STATUS" = 0 ] \
  || { printf 'TEST_FAILURE\n' > "$DIAGNOSTICS/classification.txt"; TERMINAL=1; exit "${STATUS:-1}"; }

# Coverage must be a complete, parseable Cobertura document with at least one
# class and line. Missing/empty/truncated output is never accepted.
python3 - "$COVERAGE_FILE" <<'PY'
import os, sys, xml.etree.ElementTree as ET
path = sys.argv[1]
if not os.path.isfile(path) or os.path.getsize(path) == 0:
    raise SystemExit("coverage missing or empty")
root = ET.parse(path).getroot()
if (root.tag != "coverage" or next(root.iter("class"), None) is None
        or next(root.iter("line"), None) is None):
    raise SystemExit("coverage partial or contains no executable evidence")
PY
printf 'PASSED\n' > "$DIAGNOSTICS/classification.txt"
TERMINAL=1
event passed "$COVERAGE_FILE"
