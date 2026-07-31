#!/usr/bin/env bash
# rc-gate-smoke.sh — RC gate: DI-wiring proof via cut-time smoke boot. ZERO AI.
#
# Locked model (Crom, 2026-07-28): the cut itself must prove the published artifact's
# service wiring actually resolves — staging never receives an RC whose host cannot
# even construct itself. The gate boots the ACTUAL published output ($PUBLISH_DIR) on a
# loopback port under a neutral throwaway environment, and passes only when the process
# stays alive AND answers HTTP within the window. Any HTTP answer proves the generic
# host built (all hosted services + middleware pipeline constructed = the DI graph
# resolved) and Kestrel bound. Fail-closed: early exit, no bind, or silence refuses.
#
# Env in : PUBLISH_DIR (required) · APP_DLL (entry dll name, required)
#          RC_SMOKE_TIMEOUT (secs to first answer, default 90)
#          RC_SMOKE_PATH (probe path, default /) · RC_SMOKE_EXPECT (any|<code>, default any)
#          RC_SMOKE_ASPNET_ENV (default RcSmoke — loads base appsettings.json only;
#            never Development [seeders] and never Staging/Production [real config])
#          RC_SMOKE_PORT (first candidate port, default 18811)
# Optional per-repo boot env (NON-SECRET only): .github/scripts/ci/rc-smoke.env
#   (KEY=VALUE lines, exported into the boot — e.g. a feature kill-switch).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$HERE/../.." && pwd)/lib/common.sh"

PUBLISH_DIR="${PUBLISH_DIR:?PUBLISH_DIR required}"
APP_DLL="${APP_DLL:?APP_DLL required}"
[ -d "$PUBLISH_DIR" ] || die "smoke: PUBLISH_DIR '$PUBLISH_DIR' is not a directory — fail-closed" 2
[ -f "$PUBLISH_DIR/$APP_DLL" ] || die "smoke: entry dll '$APP_DLL' not in publish output — fail-closed" 2
require curl
require dotnet
require setsid

TIMEOUT="${RC_SMOKE_TIMEOUT:-90}"
PROBE_PATH="${RC_SMOKE_PATH:-/}"
EXPECT="${RC_SMOKE_EXPECT:-any}"
ASPENV="${RC_SMOKE_ASPNET_ENV:-RcSmoke}"

# Free loopback port: first candidate from RC_SMOKE_PORT that nothing listens on.
PORT=""
for p in $(seq "${RC_SMOKE_PORT:-18811}" "$(( ${RC_SMOKE_PORT:-18811} + 19 ))"); do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT="$p"; break; fi
  exec 3>&- 2>/dev/null || true
done
[ -n "$PORT" ] || die "smoke: no free loopback port in candidate range — fail-closed" 2

BOOTLOG="$(mktemp)"
log "smoke: booting $APP_DLL on 127.0.0.1:$PORT (env $ASPENV, timeout ${TIMEOUT}s)"

# Optional committed, non-secret boot env from the repo.
ENVFILE=".github/scripts/ci/rc-smoke.env"
if [ -f "$ENVFILE" ]; then
  log "smoke: applying repo boot env $ENVFILE"
  set -a; # shellcheck disable=SC1090
  . "$ENVFILE"; set +a
fi

(
  cd "$PUBLISH_DIR" || exit 3
  ASPNETCORE_URLS="http://127.0.0.1:$PORT" \
  ASPNETCORE_ENVIRONMENT="$ASPENV" \
  DOTNET_ENVIRONMENT="$ASPENV" \
  DOTNET_gcServer=0 \
  exec setsid dotnet "./$APP_DLL"
) >"$BOOTLOG" 2>&1 &
PID=$!

# The boot runs as its own session/process-group leader (setsid): cleanup kills the
# WHOLE group so nothing the app spawned survives the gate.
# shellcheck disable=SC2317  # invoked via the EXIT trap only
cleanup() {
  kill -- "-$PID" 2>/dev/null || kill "$PID" 2>/dev/null || true
  for _ in 1 2 3 4 5; do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
  kill -9 -- "-$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}
trap cleanup EXIT

refuse() { # $1 = reason
  err "smoke: $1 — RC refused (DI-wiring proof failed)"
  err "smoke: last boot output:"
  tail -30 "$BOOTLOG" | sed 's/^/   | /' >&2
  rm -f "$BOOTLOG"
  exit 1
}

DEADLINE=$(( SECONDS + TIMEOUT ))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    refuse "process exited before answering (host/DI construction failed)"
  fi
  # -w prints the code on stdout even when curl exits non-zero (000 on no-connect);
  # capture it alone and sanitize — a malformed capture must read as "no answer".
  CODE="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT$PROBE_PATH" 2>/dev/null || true)"
  case "$CODE" in [0-9][0-9][0-9]) ;; *) CODE=000 ;; esac
  if [ "$CODE" != "000" ]; then
    if [ "$EXPECT" = "any" ] || [ "$CODE" = "$EXPECT" ]; then
      note "smoke: host up, HTTP $CODE on $PROBE_PATH — DI wiring proven."
      rm -f "$BOOTLOG"
      exit 0
    fi
    refuse "answered HTTP $CODE on $PROBE_PATH but policy expects $EXPECT"
  fi
  sleep 2
done
refuse "no HTTP answer within ${TIMEOUT}s (host never bound)"
