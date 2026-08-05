#!/usr/bin/env python3
"""Fail-closed contract comparison for structured EF migration evidence."""

import argparse
import hashlib
import json
import os
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(message)


def load_declarations(directory: Path) -> dict[str, dict]:
    declarations = {}
    if not directory.is_dir():
        fail(f"migration declaration directory is missing: {directory}")
    for path in sorted(directory.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        migration = data.get("migration")
        if not isinstance(migration, str) or not migration:
            fail(f"invalid migration declaration identity: {path}")
        if migration in declarations:
            fail(f"duplicate migration declaration: {migration}")
        declarations[migration] = data
    return declarations


def validate_declaration(migration: dict, declaration: dict) -> None:
    declared = declaration.get("classification")
    if declared not in ("pure-additive", "data-sensitive"):
        fail(f"invalid declaration classification: {migration['migration']}")
    expected = declaration.get("expected")
    if not isinstance(declaration.get("affected_tables"), list) or not isinstance(expected, dict):
        fail(f"incomplete declaration: {migration['migration']}")
    if expected.get("rows_preserved") is not True or expected.get("relationships_preserved") is not True:
        fail(f"preservation expectations must be explicit and true: {migration['migration']}")
    if not isinstance(expected.get("backfills"), list):
        fail(f"backfills must be a list: {migration['migration']}")
    if migration["classification"] == "data-sensitive" and declared == "pure-additive":
        fail(f"risky-to-additive downgrade rejected: {migration['migration']}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inspection", required=True)
    parser.add_argument("--declarations", required=True)
    parser.add_argument("--previous-migration", default="")
    parser.add_argument("--baseline-source-sha", default="")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    inspection_bytes = Path(args.inspection).read_bytes()
    inspection = json.loads(inspection_bytes)
    if inspection.get("classifierVersion") != "tier0-structured-v1":
        fail("unknown or missing structured classifier version")
    migrations = sorted(inspection.get("migrations", []), key=lambda item: item.get("migration", ""))
    changed = [item for item in migrations if item.get("migration", "") > args.previous_migration]
    declarations = load_declarations(Path(args.declarations))
    for migration in changed:
        declaration = declarations.get(migration["migration"])
        if declaration is None:
            fail(f"missing declaration: {migration['migration']}")
        validate_declaration(migration, declaration)

    risky = [item["migration"] for item in changed if item["classification"] == "data-sensitive"]
    if not changed:
        outcome, route = "NOT_REQUIRED", "none"
    elif risky and not args.baseline_source_sha:
        outcome, route = "QUARANTINED_NO_BASELINE", "quarantine"
    elif risky:
        outcome, route = "PENDING_POPULATED_UPGRADE", "populated-upgrade"
    else:
        outcome, route = "PENDING_ADDITIVE_EMPTY", "additive-empty"

    result = {
        "schema": 1,
        "classifierVersion": inspection["classifierVersion"],
        "classifierEvidenceSha256": hashlib.sha256(inspection_bytes).hexdigest(),
        "previousMigration": args.previous_migration or None,
        "previousAcceptedSourceSha": args.baseline_source_sha or None,
        "candidateMigrations": [item["migration"] for item in changed],
        "riskyMigrations": risky,
        "route": route,
        "outcome": outcome,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, output)
    print(outcome)


if __name__ == "__main__":
    main()
