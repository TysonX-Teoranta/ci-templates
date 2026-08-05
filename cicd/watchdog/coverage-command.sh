#!/usr/bin/env bash
# Adapts a real coverage command to the watchdog's explicit phase/heartbeat contract.
set -euo pipefail
if [ "$#" -lt 4 ] || [ "$3" != -- ]; then
  echo "usage: coverage-command.sh EVIDENCE_DIR COVERAGE_SOURCE -- COMMAND..." >&2
  exit 64
fi
EVIDENCE=$1
COVERAGE_SOURCE=$2
shift 3
[ -d "$EVIDENCE" ] || { echo "watchdog evidence directory is missing" >&2; exit 66; }
case "$COVERAGE_SOURCE" in /*) ;; *) COVERAGE_SOURCE="$PWD/$COVERAGE_SOURCE" ;; esac

PHASE="$EVIDENCE/phase"
HEARTBEAT="$EVIDENCE/heartbeat"
printf 'coverage\n' > "$PHASE"
date +%s > "$HEARTBEAT"
export TIER0_HEARTBEAT_FILE="$HEARTBEAT"

"$@" &
COMMAND_PID=$!
SEEN_TESTHOST=0
LAST_PHASE=coverage
while kill -0 "$COMMAND_PID" 2>/dev/null; do
  if python3 - "$COMMAND_PID" <<'PY'
import os, sys
pending = [int(sys.argv[1])]
seen = set()
while pending:
    parent = pending.pop()
    if parent in seen:
        continue
    seen.add(parent)
    for item in os.scandir('/proc'):
        if not item.name.isdigit():
            continue
        try:
            stat = open(f'/proc/{item.name}/stat', encoding='ascii').read().split()
            if int(stat[3]) != parent:
                continue
            pid = int(item.name)
            pending.append(pid)
            command = open(f'/proc/{pid}/cmdline', 'rb').read().replace(b'\0', b' ')
            if b'testhost.dll' in command:
                raise SystemExit(0)
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
            pass
raise SystemExit(1)
PY
  then
    SEEN_TESTHOST=1
    if [ "$LAST_PHASE" != test ]; then printf 'test\n' > "$PHASE"; LAST_PHASE="test"; fi
  elif [ "$SEEN_TESTHOST" -eq 1 ] && [ "$LAST_PHASE" != coverage-processing ]; then
    printf 'coverage-processing\n' > "$PHASE"
    date +%s > "$HEARTBEAT"
    LAST_PHASE="coverage-processing"
  fi
  sleep 2
done

set +e
wait "$COMMAND_PID"
STATUS=$?
set -e
[ "$STATUS" -eq 0 ] || exit "$STATUS"
[ -s "$COVERAGE_SOURCE" ] || { echo "coverage command succeeded without its declared report" >&2; exit 1; }
cp "$COVERAGE_SOURCE" "$EVIDENCE/coverage.xml"
