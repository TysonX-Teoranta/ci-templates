#!/usr/bin/env bash
# Root boundary for the Pulse-hosted authorization store and its root-only keys.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "rc authorization entrypoint requires sudo" >&2; exit 77; }
[ "${SUDO_USER:-}" = tysonxpulse ] || { echo "refusing unexpected caller" >&2; exit 77; }
[ "$#" -gt 0 ] || exit 2

case "$1" in
  claim)
    # Non-interactive workflow operation. The Python boundary validates the exact
    # authorization, actor, domain, signature, expiry, replay and singleton state.
    ;;
  lifecycle)
    # Non-interactive terminal-state recording; lifecycle IDs are unguessable.
    ;;
  issue|recover)
    # Authorization creation and stale recovery are explicit operator actions and
    # can never be invoked by a non-interactive Actions job.
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      echo "operator action requires an interactive terminal" >&2
      exit 77
    fi
    ;;
  *)
    echo "unsupported rc authorization operation" >&2
    exit 2
    ;;
esac

umask 077
exec /usr/local/libexec/tier0/rc-authorization.py \
  --store /var/lib/tier0/rc-authorizations.sqlite3 "$@"
