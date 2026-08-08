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

# Realistic vstest trx shape (proven live 2026-08-08): Results carry the bare
# method DISPLAY name in testName; the class path lives in TestDefinitions and
# joins back via executionId. One legacy full-name row proves that shape still
# matches too.
mkdir -p "$WORK/results"
cat > "$WORK/results/rc-tests.trx" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <Results>
    <UnitTestResult executionId="e1" testName="DuplicateEventIsNoOp" outcome="Passed" />
    <UnitTestResult executionId="e2" testName="SuspendedUserCannotLogin" outcome="Failed" />
    <UnitTestResult executionId="e3" testName="EraseRemovesPii(1)" outcome="Passed" />
    <UnitTestResult executionId="e4" testName="EraseRemovesPii(2)" outcome="Passed" />
    <UnitTestResult executionId="e5" testName="EraseRemovesPiiPartial(1)" outcome="Passed" />
    <UnitTestResult executionId="e6" testName="EraseRemovesPiiPartial(2)" outcome="NotExecuted" />
    <UnitTestResult executionId="e7" testName="App.Tests.Legacy.FullNameTests.LegacyFullNameRow" outcome="Passed" />
  </Results>
  <TestDefinitions>
    <UnitTest id="d1"><Execution id="e1" /><TestMethod className="App.Tests.Payments.WebhookTests, App.Tests" name="DuplicateEventIsNoOp" /></UnitTest>
    <UnitTest id="d2"><Execution id="e2" /><TestMethod className="App.Tests.Auth.SuspendTests" name="SuspendedUserCannotLogin" /></UnitTest>
    <UnitTest id="d3"><Execution id="e3" /><TestMethod className="App.Tests.Gdpr.EraseTests" name="EraseRemovesPii(1)" /></UnitTest>
    <UnitTest id="d4"><Execution id="e4" /><TestMethod className="App.Tests.Gdpr.EraseTests" name="EraseRemovesPii(2)" /></UnitTest>
    <UnitTest id="d5"><Execution id="e5" /><TestMethod className="App.Tests.Gdpr.EraseTests" name="EraseRemovesPiiPartial(1)" /></UnitTest>
    <UnitTest id="d6"><Execution id="e6" /><TestMethod className="App.Tests.Gdpr.EraseTests" name="EraseRemovesPiiPartial(2)" /></UnitTest>
  </TestDefinitions>
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

# 11. legacy shape — full name directly in testName, no definition row -> pass
manifest "App.Tests.Legacy.FullNameTests.LegacyFullNameRow" > "$WORK/c.yml"
CONTRACTS_FILE="$WORK/c.yml" TRX_DIR="$WORK/results" bash "$GATE" >/dev/null 2>&1
ok "contracts/legacy-fullname-pass" "$?" "0"

echo "test-rc-contracts: $PASS passed, $FAIL failed" >&2
[ "$FAIL" -eq 0 ] || exit 1
exit 0
