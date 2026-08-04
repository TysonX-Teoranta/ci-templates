#!/usr/bin/env bash
# Narrow sudo entrypoint for the primary runner. The command is unprivileged;
# root is retained only by the cgroup supervisor and bounded dump collector.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "primary watchdog entrypoint requires sudo" >&2; exit 77; }
[ "${SUDO_USER:-}" = tysonxdev ] || { echo "refusing unexpected caller" >&2; exit 77; }
if [ "$#" -lt 3 ] || [ "$2" != -- ]; then
  echo "usage: tier0-test-watchdog EVIDENCE_DIR -- COMMAND..." >&2
  exit 2
fi
EVIDENCE_DIR="$1"
shift 2
case "$EVIDENCE_DIR" in
  /home/deploy/actions-runner-org/_work/_temp/tier0-watchdog-*) ;;
  *) echo "refusing evidence path outside runner temp" >&2; exit 77 ;;
esac
[ ! -L "$EVIDENCE_DIR" ] || { echo "refusing symlink evidence path" >&2; exit 77; }
install -d -o tysonxdev -g tysonxdev -m 0700 "$EVIDENCE_DIR"
EVIDENCE_DIR=$(realpath -e "$EVIDENCE_DIR")
case "$EVIDENCE_DIR" in
  /home/deploy/actions-runner-org/_work/_temp/tier0-watchdog-*) ;;
  *) echo "refusing resolved evidence path" >&2; exit 77 ;;
esac
exec /usr/local/libexec/tier0/test-watchdog.sh \
  --heartbeat "$EVIDENCE_DIR/heartbeat" --phase-file "$EVIDENCE_DIR/phase" \
  --coverage "$EVIDENCE_DIR/coverage.xml" --diagnostics "$EVIDENCE_DIR/diagnostics" \
  --test-deadline 8100 --coverage-deadline 1800 --coverage-processing-deadline 600 \
  --progress-deadline 1500 --dump-deadline 120 --cpu-quota 400% --memory-max 15G \
  --run-as-user tysonxdev -- "$@"
