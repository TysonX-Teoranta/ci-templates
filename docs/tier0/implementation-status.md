# Tier 0 implementation status

Updated: 2026-08-07

Enforcement: LIVE. The complete ordered end-to-end proof passed on 2026-08-07 —
authorized singleton devRC run 31187532725 cut `v0.1.1-rc.17` with lifecycle
`complete`; the Pulse operator surface (`devrc`) is installed and proven.

## Implemented and locally accepted

- systemd/cgroup watchdog, bounded dump collection, full descendant cleanup, runner-health checks, coverage XML
  validation, and exactly one infrastructure-only retry;
- transactional SQLite TOTP authorization and singleton lifecycle records, signed short-lived authorization IDs,
  replay/expiry checks, stale lifecycle recovery, and retained audit history;
- exact-SHA Lodgers deployment from an isolated `/tmp` clone using `/home/deploy/repo/lodgers-ai` as the existing
  object/reference base, atomic activation/rollback, tree and published-file checksums, and release identity;
- build identity in `/health`, pre-Playwright source-SHA rejection, and Playwright identity evidence;
- commit/tree/artifact source evidence with fail-closed tracked-change, unexpected-untracked, and tamper checks;
- structured EF `MigrationOperation` inspection with a strict `CreateTable` / nullable `AddColumn` allowlist;
- migration declarations, risky-to-additive downgrade rejection, missing-baseline quarantine, and deterministic
  additive/populated routing;
- disposable PostgreSQL runner with idempotent reapplication, schema/data fingerprints, affected-table row-count
  preservation, exact candidate boot, and real migration-history/write/read/rollback database probe.

## Preserved safety constraints

- No staging, live, or production path was invoked.
- No destructive watchdog test ran on a primary runner.
- No new repository was created under `/home/deploy/repo`.
- The Pulse root TOTP gate was not installed or replaced by automation.
- Blocking enforcement remains off until every acceptance scenario in the approved plan passes.

## Acceptance evidence

- Disposable watchdog battery: Actions run `30967602441`, three complete repetitions on
  `ubuntu-24.04-arm`; all fault scopes were reaped and every immediate follow-up suite passed.
- Disposable migration battery: Actions run `30971253097`; additive-empty, populated-upgrade,
  structured unknown-to-risky routing, downgrade rejection, missing-baseline quarantine,
  fixture failure, and EF script-generation failure all produced their required outcomes.
- Exact-SHA deployment harness: branch advance, unavailable object, published-file tamper, and
  post-flip identity mismatch/rollback all passed.
- Authorization and exact-source self-tests: 8 authorization, 5 source-evidence, and 5 migration
  contract scenarios passed on 2026-08-05.

## Delivered activation (2026-08-07)

The Pulse operator payload is installed (`/usr/local/bin/devrc`, root-owned) and its canary,
status, history, and second-order refusal checks all passed. The authorized singleton devRC
`v0.1.1-rc.17` completed end to end; evidence is retained on the operator workstation under
`~/tier0-evidence/`. Blocking enforcement is on for the Lodgers dev gate and RC lane.

## Tier 1 and Tier 2 (added 2026-08-07)

- Tier 1 mechanism: `rc-gate-contracts.sh` — the product repo's `cicd/contracts.yml` declares
  invariant tests that must exist and pass in the RC trx; fail closed; `contracts: required`
  in the registry makes the manifest itself mandatory. The risk-weighted test-quality audit
  that extends the manifest is tracked separately.
- Tier 2 mechanism: the report-only `analyse` job in `_finalise-rc.yml` (`rc-analyse.sh`) —
  coverage ratchet plus scoped Stryker mutation over `cicd/mutation/*.json`, run at RC time
  on the exact cut source, hard-capped per domain. The nightly crons are retired; domain
  callers keep `workflow_dispatch` only. Mutation stays non-blocking until execution is
  stable, survivors are understood, and thresholds are agreed (per the approved plan).
