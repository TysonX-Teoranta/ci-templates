#!/usr/bin/env bash
# ci/rc-publish.sh — RC GATE build-once: produce the publish artifact ONCE and echo its path.
#
# SPEC principle: "Build ONCE, promote the SAME hashed artifact." The publish-based RC gates
# (Check3 provenance, Check12 IL fake-scan, Check14 parity-clean) all operate on this one
# artifact. This helper publishes it on first call and reuses it for the rest of the cut,
# memoized on the git HEAD sha so a single cut publishes exactly once.
#
# Contract: prints ONLY the publish directory on stdout (all dotnet noise -> stderr); exits
# non-zero on any publish failure so callers fail closed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WEB_PROJECT="${WEB_PROJECT:-LodgersSite/LodgersSite.csproj}"
PUB_DIR="${RC_PUBLISH_DIR:-$REPO_ROOT/.rc-publish}"
RID="${RC_PUBLISH_RID:-linux-x64}"          # staging/live are x86; ship the x64 artifact.
STAMP="$PUB_DIR/.rc-publish.sha"
APP_DLL="$(basename "$WEB_PROJECT" .csproj).dll"

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo nogit)"

# Reuse a publish already produced for this exact HEAD within the cut.
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$HEAD_SHA" ] && [ -f "$PUB_DIR/$APP_DLL" ]; then
  printf '%s\n' "$PUB_DIR"
  exit 0
fi

rm -rf "$PUB_DIR"
# NuGet vuln audit (NU190x) is the separate Check8 gate; this build-once publish must not be
# coupled to it — RC_PUBLISH_NUGET_AUDIT=false lets a local artifact proof run while a dep bump
# is in flight. CI leaves it unset (audit on) so a real cut still honours Check8 at A1.2.
AUDIT_ARG=()
[ "${RC_PUBLISH_NUGET_AUDIT:-}" = "false" ] && AUDIT_ARG=(-p:NuGetAudit=false)

dotnet publish "$REPO_ROOT/$WEB_PROJECT" -c Release -r "$RID" --self-contained false \
  -o "$PUB_DIR" --verbosity quiet "${AUDIT_ARG[@]}" 1>&2

[ -f "$PUB_DIR/$APP_DLL" ] || die "rc-publish: artifact $APP_DLL absent after publish — failing closed."
printf '%s' "$HEAD_SHA" > "$STAMP"
printf '%s\n' "$PUB_DIR"
