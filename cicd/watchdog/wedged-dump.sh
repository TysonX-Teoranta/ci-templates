#!/usr/bin/env bash
set -euo pipefail
printf 'fake dump collector started pid=%s\n' "$$"
printf '%s\n' "$$" > "${TIER0_DUMP_PID_FILE:?}"
sleep 30
