#!/usr/bin/env bash
# rc-gate-contracts.sh — behavioural-contract gate (Tier 1 mechanism; Crom 2026-08-07).
# The product repo commits cicd/contracts.yml declaring the invariant tests that
# MUST exist and pass in the RC test results. Same fail-closed doctrine as the
# migration contract: a declaration can never weaken reality —
#   - manifest present + any declared test missing/failing/skipped -> refuse;
#   - manifest present but empty                                    -> refuse;
#   - manifest absent -> gate not armed (unless CONTRACTS_REQUIRED=1 -> refuse).
# Zero AI: committed manifest vs committed test results, nothing else.
#
# Manifest format (strict, two keys per entry):
#   contracts:
#     - invariant: "<human sentence — what must always hold>"
#       test: "<Namespace.Class.Method — exact full test name>"
# A parameterized contract test matches "<name>(...)"; every case must pass.
#
# Env in : CONTRACTS_FILE (default cicd/contracts.yml) · TRX_DIR (required when armed)
#          CONTRACTS_REQUIRED 0|1 (registry: contracts: required)
# Exit   : 0 pass / not armed · 1 refused · 2 usage / bad manifest · 3 infra
set -uo pipefail

# shellcheck source=../../lib/common.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

CONTRACTS_FILE="${CONTRACTS_FILE:-cicd/contracts.yml}"
CONTRACTS_REQUIRED="${CONTRACTS_REQUIRED:-0}"

if [ ! -f "$CONTRACTS_FILE" ]; then
  if [ "$CONTRACTS_REQUIRED" = "1" ]; then
    die "contracts are required for this domain but $CONTRACTS_FILE is missing — refuse to cut" 1
  fi
  note "no $CONTRACTS_FILE — contract gate not armed for this repo"
  exit 0
fi

require python3
TRX_DIR="${TRX_DIR:?TRX_DIR is required when a contracts manifest is present}"
TRX="$(find "$TRX_DIR" -name '*.trx' 2>/dev/null | head -1)"
[ -n "$TRX" ] || die "contracts manifest present but no .trx test results found in $TRX_DIR" 3

# Strict manifest parse: every '- invariant:' must pair with a 'test:'.
mapfile -t DECLARED < <(awk '
  /^[[:space:]]*test:[[:space:]]*/ {
    line = $0
    sub(/^[[:space:]]*test:[[:space:]]*/, "", line)
    gsub(/^["'\'']|["'\'']$/, "", line)
    if (line != "") print line
  }' "$CONTRACTS_FILE")
N_INVARIANTS="$(grep -cE '^[[:space:]]*-[[:space:]]*invariant:' "$CONTRACTS_FILE" || true)"

[ "${#DECLARED[@]}" -gt 0 ] || die "$CONTRACTS_FILE is present but declares no tests — an empty manifest is a mistake, not a pass" 2
[ "${#DECLARED[@]}" -eq "$N_INVARIANTS" ] || die "$CONTRACTS_FILE malformed: ${#DECLARED[@]} test entries vs $N_INVARIANTS invariant entries" 2

log "contract gate: ${#DECLARED[@]} declared invariant(s) vs $TRX"
DECL_LIST="$(mktemp)"
trap 'rm -f "$DECL_LIST"' EXIT
printf '%s\n' "${DECLARED[@]}" > "$DECL_LIST"
FAILED=0
while IFS= read -r verdict; do
  case "$verdict" in
    OK*)  log "contract $verdict" ;;
    *)    err "contract $verdict"; FAILED=1 ;;
  esac
done < <(python3 - "$TRX" "$DECL_LIST" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

# vstest's trx logger records testName as the DISPLAY name (for NUnit that is
# the bare method), and parks the class path in TestDefinitions/TestMethod
# @className. Matching a declared Namespace.Class.Method therefore needs the
# definitions joined back on: fqn = className + "." + methodName. Proven live
# 2026-08-08 (run 31249821403: all five contracts false-MISSING on testName).
trx = sys.argv[1]
with open(sys.argv[2]) as f:
    declared = [l.strip() for l in f if l.strip()]
root = ET.parse(trx).getroot()

fqn_by_id = {}
for d in root.iter():
    if not d.tag.endswith("UnitTest"):
        continue
    exec_ids = [e.get("id", "") for e in d.iter() if e.tag.endswith("Execution")]
    for m in d.iter():
        if m.tag.endswith("TestMethod"):
            fqn = m.get("className", "").split(",")[0] + "." + m.get("name", "")
            for eid in exec_ids or [d.get("id", "")]:
                fqn_by_id[eid] = fqn

results = {}  # matchable name -> outcome (keeps worst outcome per name)
for r in root.iter():
    if not r.tag.endswith("UnitTestResult"):
        continue
    outcome = r.get("outcome", "")
    names = {r.get("testName", "")}
    eid = r.get("executionId", "") or r.get("testId", "")
    if eid in fqn_by_id:
        names.add(fqn_by_id[eid])
    for n in names:
        if n and (n not in results or results[n] == "Passed"):
            results[n] = outcome

for name in declared:
    hits = {k: v for k, v in results.items() if k == name or k.startswith(name + "(")}
    if not hits:
        print(f"MISSING: {name} — declared invariant has no test in the RC results")
        continue
    bad = {k: v for k, v in hits.items() if v != "Passed"}
    if bad:
        for k, v in sorted(bad.items()):
            print(f"NOT-PASSED ({v}): {k}")
    else:
        print(f"OK ({len(hits)} case(s)): {name}")
PYEOF
)

[ "$FAILED" -eq 0 ] || die "contract gate refused the RC — a declared invariant is unproven" 1
log "contract gate: all ${#DECLARED[@]} invariant(s) proven"
exit 0
