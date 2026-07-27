#!/usr/bin/env bash
# rc-gate-secrets.sh — RC gate: refuse the cut if a secret (API key, token, password,
# private key) is present in a target tree. ZERO AI: gitleaks runs deterministic regex +
# entropy rules (NOT any ML/AI detector). Invoked by rc-finalise twice — over the source
# working tree (post-scrub) and over the built $PUBLISH_DIR — since staging (= live) must
# never receive a leaked credential.
#
# gitleaks is not a dotnet tool; if absent it is fetched once from the pinned GitHub
# release for the runner arch into a tool dir. Fail-closed: any fetch/scan error, or any
# finding, refuses the RC. No clearance path — a real secret must be rotated + removed.
#
# Env in : TARGET (dir to scan, required); GITLEAKS_VERSION (pinned, default below);
#          TOOLDIR (where to cache the binary; default $WORKROOT/.gitleaks or /tmp).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$HERE/../.." && pwd)/lib/common.sh"

TARGET="${TARGET:?TARGET dir required}"
[ -d "$TARGET" ] || die "secrets: TARGET '$TARGET' is not a directory — fail-closed" 2
require curl
require tar

GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.21.2}"
TOOLDIR="${TOOLDIR:-${WORKROOT:-/tmp}/.gitleaks}"
BIN="$TOOLDIR/gitleaks"
mkdir -p "$TOOLDIR"

# Resolve runner arch → gitleaks release asset naming (x64|arm64).
case "$(uname -m)" in
  x86_64|amd64) GARCH="x64" ;;
  aarch64|arm64) GARCH="arm64" ;;
  *) die "secrets: unsupported arch $(uname -m) for gitleaks — fail-closed" 2 ;;
esac

if [ ! -x "$BIN" ]; then
  URL="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GARCH}.tar.gz"
  log "secrets: fetching gitleaks v$GITLEAKS_VERSION ($GARCH)"
  curl -fsSL "$URL" -o "$TOOLDIR/gitleaks.tgz" \
    || die "secrets: gitleaks download failed ($URL) — fail-closed" 1
  tar -C "$TOOLDIR" -xzf "$TOOLDIR/gitleaks.tgz" gitleaks \
    || die "secrets: gitleaks extract failed — fail-closed" 1
  chmod +x "$BIN"
fi

REPORT="$(mktemp)"
log "secrets: scanning $TARGET (gitleaks, deterministic rules)"
# --no-git: scan the working tree / publish dir as files (not git history).
# Exit 1 = leaks found; exit >1 = tool error. Both must refuse the RC.
"$BIN" detect --source "$TARGET" --no-git --redact --report-format json --report-path "$REPORT" --exit-code 1
rc=$?
if [ "$rc" -eq 0 ]; then
  rm -f "$REPORT"; note "secrets: no leaks in $TARGET — clean."; exit 0
fi
if [ "$rc" -eq 1 ]; then
  n="$(jq 'length' "$REPORT" 2>/dev/null || echo '?')"
  err "secrets: $n leak(s) detected in $TARGET — RC refused (no clearance path: rotate + remove):"
  jq -r '.[] | "   - \(.RuleID) @ \(.File):\(.StartLine)"' "$REPORT" 2>/dev/null | sort -u | head -30 >&2
  rm -f "$REPORT"; exit 1
fi
rm -f "$REPORT"
die "secrets: gitleaks errored (exit $rc) — fail-closed" 1
