#!/usr/bin/env bash
# rc-gate-dep-vuln.sh — RC gate: refuse the cut if any NuGet dependency (direct OR
# transitive) has a known vulnerability at/above a severity floor. ZERO AI: this is a
# static lookup against the .NET SDK's own advisory feed (`dotnet list package
# --vulnerable`), parsed deterministically with jq. No model, no network-to-AI.
#
# Invoked by rc-finalise.sh AFTER restore (the SDK needs the restore graph). Fail-closed:
# any tool/parse error or a finding at/above the floor refuses the RC.
#
# Env in : PROJECT (the .sln/.csproj to scan; rc-finalise passes SOLUTION) and, optionally,
#          RC_VULN_FLOOR (Low|Moderate|High|Critical; default High). rc-finalise sources
#          the domain's .github/scripts/ci/rc.conf first so a per-domain floor is honoured.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$HERE/../.." && pwd)/lib/common.sh"

PROJECT="${PROJECT:?PROJECT (sln/csproj) required}"
require dotnet
require jq

FLOOR="${RC_VULN_FLOOR:-High}"
rank() { case "$1" in Low) echo 1;; Moderate) echo 2;; High) echo 3;; Critical) echo 4;; *) echo 0;; esac; }
FLOOR_RANK="$(rank "$FLOOR")"
[ "$FLOOR_RANK" -ge 1 ] || die "invalid RC_VULN_FLOOR '$FLOOR' (Low|Moderate|High|Critical)" 2

log "dep-vuln: scanning $PROJECT for vulnerabilities >= $FLOOR (SDK advisory feed)"
OUT="$(mktemp)"
# --format json is deterministic + machine-readable (.NET SDK >= 8). Fail closed if the
# command itself errors (network to nuget advisory db down, bad restore, etc.).
if ! dotnet list "$PROJECT" package --vulnerable --include-transitive --format json > "$OUT" 2>/dev/null; then
  rm -f "$OUT"; die "dotnet list --vulnerable failed (restore first / advisory feed unreachable) — RC refused (fail-closed)" 1
fi

# Collect every vulnerability whose severity rank >= floor, across top-level + transitive,
# all frameworks. jq lowercases nothing; the SDK emits "Low/Moderate/High/Critical".
HITS="$(jq -r --argjson floor "$FLOOR_RANK" '
  def rank(s): {"low":1,"moderate":2,"high":3,"critical":4}[s|ascii_downcase] // 0;
  [ .projects[]?.frameworks[]?
    | (.topLevelPackages // empty), (.transitivePackages // empty) ]
  | flatten
  | map(select(.vulnerabilities != null))
  | .[] as $p
  | $p.vulnerabilities[]
  | select(rank(.severity) >= $floor)
  | "\($p.id) \($p.resolvedVersion) — \(.severity) \(.advisoryurl)"
' "$OUT" 2>/dev/null || true)"
rm -f "$OUT"

if [ -n "$HITS" ]; then
  err "dep-vuln: vulnerable dependencies at/above $FLOOR — RC refused:"
  printf '%s\n' "$HITS" | sed 's/^/   - /' >&2
  err "Fix: bump the offending package(s) on dev, or (if a false positive) pin+document. No clearance path here — a known-vulnerable dep must not ship to staging (= live)."
  exit 1
fi
note "dep-vuln: no dependencies vulnerable at/above $FLOOR — clean."
exit 0
