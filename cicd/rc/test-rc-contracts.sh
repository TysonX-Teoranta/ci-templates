#!/usr/bin/env bash
# test-rc-contracts.sh — offline acceptance battery for rc-gate-contracts.sh.
# Synthetic trx + manifests; every fail-closed path must refuse, every clean path pass.
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gates/rc-gate-contracts.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { # name actual expected
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 (got $2 want $3)" >&2; fi
}

mkdir -p "$WORK/results"
cat > "$WORK/results/rc-tests.trx" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <Results>
    <UnitTestResult testName="App.Tests.Payments.WebhookTests.DuplicateEventIsNoOp" outcome="Passed" />
    <UnitTestResult testName="App.Tests.Auth.SuspendTests.SuspendedUserCannotLogin" outcome="Failed" />
    <UnitTestResult testName="App.Tests.Gdpr.EraseTests.EraseRemovesPii(1)" outcome="Passed" />
    <UnitTestResult testName="App.Tests.Gdpr.EraseTests.EraseRemovesPii(2)" outcome="Passed" />
    <UnitTestResult testName="App.Tests.Gdpr.EraseTests.EraseRemovesPiiPartial(1)" outcome="Passed" />
    <UnitTestResult testName="App.Tests.Gdpr.EraseTests.EraseRemovesPiiPartial(2)" outcome="NotExecuted" />
  </Results>
</TestRun>
EOF

manifest() { printf 'contracts:\n'; while [ $# -gt 0 ]; do printf -- '  - invariant: "inv"\n    test: "%s"\n' "$1"; shift; done; }

# 1. clean pass — exact name, Passed
manifest "App.Tests.Payments.WebhookTests.DuplicateEventIsNoOp" > "$WORK/c.yml"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/exact-pass" "$?" "0"

# 2. declared test failing -> refuse
manifest "App.Tests.Auth.SuspendTests.SuspendedUserCannotLogin" > "$WORK/c.yml"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/failing-refused" "$?" "1"

# 3. declared test absent from results -> refuse
manifest "App.Tests.Nothing.Here.MissingTest" > "$WORK/c.yml"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/missing-refused" "$?" "1"

# 4. parameterized contract, all cases pass -> pass
manifest "App.Tests.Gdpr.EraseTests.EraseRemovesPii" > "$WORK/c.yml"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/parameterized-all-pass" "$?" "0"

# 5. parameterized contract, one case skipped -> refuse
manifest "App.Tests.Gdpr.EraseTests.EraseRemovesPiiPartial" > "$WORK/c.yml"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/parameterized-skip-refused" "$?" "1"

# 6. manifest absent, not required -> not armed, pass
CONTRACTS_FILE="$WORK/absent.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/absent-not-armed" "$?" "0"

# 7. manifest absent but registry requires contracts -> refuse
CONTRACTS_FILE="$WORK/absent.yml" CONTRACTS_REQUIRED=1 TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/absent-required-refused" "$?" "1"

# 8. empty manifest -> refuse (a present-but-empty manifest is a mistake)
printf 'contracts: []\n' > "$WORK/c.yml"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/empty-manifest-refused" "$?" "2"

# 9. malformed manifest (invariant without test) -> refuse
printf 'contracts:\n  - invariant: "orphan"\n  - invariant: "ok"\n    test: "App.Tests.Payments.WebhookTests.DuplicateEventIsNoOp"\n' > "$WORK/c.yml"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/malformed-refused" "$?" "2"

# 10. manifest present but no trx anywhere -> infra failure, never a pass
manifest "App.Tests.Payments.WebhookTests.DuplicateEventIsNoOp" > "$WORK/c.yml"
mkdir -p "$WORK/empty-results"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/empty-results" bash "$GATE" >/dev/null 2>&1
ok "contracts/no-trx-refused" "$?" "3"

echo "test-rc-contracts: $PASS passed, $FAIL failed" >&2
[ "$FAIL" -eq 0 ] || exit 1
exit 0
