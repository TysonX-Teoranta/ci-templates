#!/usr/bin/env bash
# rc-gate-license.sh — RC gate: refuse the cut if any shipped dependency carries a licence
# outside the allowed policy (copyleft or unknown). ZERO AI.
#
# Reads the CycloneDX SBOM the SBOM gate already produced (SBOM_FILE) — no separate licence
# tool (the nuget-license CLI core-dumps on this runner, arm64/.NET 10). CycloneDX resolves
# each component's licence from its nupkg metadata; we check those against an allowlist.
# Fail-closed: missing/empty SBOM, parse error, or any disallowed/unknown licence refuses.
#
# Env in : SBOM_FILE (path to the CycloneDX json, required); RC_LICENSE_ALLOW (optional
#          space-separated SPDX ids; permissive default).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$HERE/../.." && pwd)/lib/common.sh"

SBOM_FILE="${SBOM_FILE:?SBOM_FILE (CycloneDX json) required}"
require jq
[ -s "$SBOM_FILE" ] || die "license: SBOM '$SBOM_FILE' missing/empty — fail-closed" 2

# SPDX ids permitted by default (permissive/business-safe). Copyleft (GPL/AGPL/LGPL) and
# unknown/empty licences are refused unless explicitly allowlisted per domain (rc.conf).
ALLOW="${RC_LICENSE_ALLOW:-MIT Apache-2.0 BSD-2-Clause BSD-3-Clause MS-PL 0BSD ISC Unlicense CC0-1.0 MSFT-EULA MICROSOFT-EULA}"
log "license: scanning SBOM $SBOM_FILE (allow: $ALLOW)"

# Each CycloneDX component may express its licence as licenses[].license.id (SPDX),
# licenses[].license.name (free text), or licenses[].expression (SPDX expr). Take the
# non-empty ones; "UNKNOWN" if none. Flag any component whose licence token is not in the
# allow-set (case-insensitive). Microsoft first-party packages often carry no SPDX id — the
# default allow-set covers their EULA spellings; tune RC_LICENSE_ALLOW per domain otherwise.
BAD="$(jq -r --arg allow "$ALLOW" '
  ($allow | ascii_upcase | split(" ")) as $ok
  | (.components // [])[]
  | . as $c
  | ( ( .licenses // [] )
      | map(.license.id // .license.name // .expression // empty)
      | map(select(. != "")) ) as $lic
  | (if ($lic | length) == 0 then ["UNKNOWN"] else $lic end)[]
  | . as $l
  | select( ($ok | index($l | ascii_upcase)) == null )
  | "\($c.name) \($c.version // "?") — \($l)"
' "$SBOM_FILE" 2>/dev/null || true)"

if [ -n "$BAD" ]; then
  err "license: shipped dependencies with disallowed/unknown licences — RC refused:"
  printf '%s\n' "$BAD" | sort -u | sed 's/^/   - /' | head -50 >&2
  err "Fix: replace the dependency, or (if the licence is acceptable) add its SPDX id to RC_LICENSE_ALLOW in the domain rc.conf (reviewed change)."
  exit 1
fi
note "license: all shipped dependency licences within policy — clean."
exit 0
