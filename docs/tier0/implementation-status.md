# Tier 0 implementation status

Updated: 2026-08-05

Enforcement: disabled pending the complete ordered end-to-end proof.

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
