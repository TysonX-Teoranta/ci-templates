#!/usr/bin/env bash
# rc-gate-license.sh — RC gate: refuse the cut if any NuGet dependency carries a licence
# outside the allowed policy (copyleft or unknown). ZERO AI: static read of package
# licence metadata via the `nuget-license` dotnet tool, checked against an allowlist.
# No model. Fail-closed on tool/parse error or any disallowed/unknown licence.
#
# Invoked by rc-finalise after restore. Allowlist is per-domain via rc.conf
# (RC_LICENSE_ALLOW, space-separated SPDX ids); default = common permissive set.
#
# Env in : PROJECT (sln/csproj, required); RC_LICENSE_ALLOW (optional override).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$HERE/../.." && pwd)/lib/common.sh"

PROJECT="${PROJECT:?PROJECT (sln/csproj) required}"
require dotnet
require jq

# SPDX ids permitted by default (permissive/business-safe). Copyleft (GPL/AGPL/LGPL)
# and unknown/empty licences are refused unless explicitly allowlisted per domain.
ALLOW="${RC_LICENSE_ALLOW:-MIT Apache-2.0 BSD-2-Clause BSD-3-Clause MS-PL 0BSD ISC Unlicense CC0-1.0 MS-EULA}"
log "license: scanning $PROJECT (allow: $ALLOW)"

TOOL="${WORKROOT:-/tmp}/.nuget-license"
[ -x "$TOOL/nuget-license" ] || dotnet tool install nuget-license --tool-path "$TOOL" >/dev/null 2>&1 \
  || die "license: nuget-license install failed — fail-closed" 1

OUT="$(mktemp)"
if ! "$TOOL/nuget-license" -i "$PROJECT" -t -o json > "$OUT" 2>/dev/null; then
  rm -f "$OUT"; die "license: nuget-license scan failed — fail-closed" 1
fi

# Build a jq allow-set and list any package whose licence is absent from it (or empty).
BAD="$(jq -r --arg allow "$ALLOW" '
  ($allow | split(" ")) as $ok
  | .[] | select((.LicenseType // "") as $l | ($ok | index($l)) == null)
  | "\(.PackageId) \(.PackageVersion) — \(.LicenseType // "UNKNOWN")"
' "$OUT" 2>/dev/null || true)"
rm -f "$OUT"

if [ -n "$BAD" ]; then
  err "license: dependencies with disallowed/unknown licences — RC refused:"
  printf '%s\n' "$BAD" | sed 's/^/   - /' | sort -u | head -40 >&2
  err "Fix: replace the dependency, or (if the licence is acceptable) add its SPDX id to RC_LICENSE_ALLOW in the domain rc.conf (reviewed change)."
  exit 1
fi
note "license: all dependency licences within policy — clean."
exit 0
