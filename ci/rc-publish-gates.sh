#!/usr/bin/env bash
# ci/rc-publish-gates.sh — RC GATE stage A1.3e: build-once publish + publish-based gates.
#
# Publishes the RC artifact ONCE (ci/rc-publish.sh) then runs every ci/rc-pubgate-*.sh against it
# in deterministic (sorted) order. Fail-closed: a missing/empty artifact, the absence of ANY
# rc-pubgate-*.sh, or any sub-gate exiting non-zero fails the whole cut.
#
# Each publish-based RC check ships as its own ci/rc-pubgate-NN-*.sh (Check3 provenance,
# Check12 IL fake-scan, Check14 parity-clean), auto-discovered here so new checks land as new
# files with no edit to this dispatcher or to rc-cut.sh.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WEB_PROJECT="${WEB_PROJECT:-LodgersSite/LodgersSite.csproj}"
APP_DLL="$(basename "$WEB_PROJECT" .csproj).dll"

PUB="$(WEB_PROJECT="$WEB_PROJECT" bash "$CI_DIR/rc-publish.sh")"
[ -n "$PUB" ] && [ -d "$PUB" ] && [ -f "$PUB/$APP_DLL" ] \
  || die "A1.3e: RC publish artifact missing ($PUB) — failing closed."
log "publish-based RC gates over artifact: $PUB"

shopt -s nullglob
gates=("$CI_DIR"/rc-pubgate-*.sh)
[ ${#gates[@]} -gt 0 ] || die "A1.3e: no rc-pubgate-*.sh present — publish-based gates missing, failing closed."

IFS=$'\n' gates=($(printf '%s\n' "${gates[@]}" | LC_ALL=C sort)); unset IFS
for g in "${gates[@]}"; do
  log "-> $(basename "$g")"
  WEB_PROJECT="$WEB_PROJECT" bash "$g" "$PUB"
done
note "A1.3e OK — publish-based RC gates green ($PUB)"
