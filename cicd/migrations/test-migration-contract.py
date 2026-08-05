#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("migration-contract.py")


class MigrationContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.declarations = self.root / "declarations"
        self.declarations.mkdir()
        self.inspection = self.root / "inspection.json"
        self.output = self.root / "route.json"

    def tearDown(self): self.temp.cleanup()

    def write_inspection(self, classification="pure-additive"):
        self.inspection.write_text(json.dumps({
            "classifierVersion": "tier0-structured-v1",
            "migrations": [{"migration": "20260101_Candidate", "classification": classification}],
        }))

    def write_declaration(self, classification="pure-additive"):
        (self.declarations / "Candidate.json").write_text(json.dumps({
            "migration": "20260101_Candidate", "classification": classification,
            "affected_tables": ["Example"],
            "expected": {"rows_preserved": True, "relationships_preserved": True, "backfills": []},
        }))

    def run_cli(self, *extra, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPT), "--inspection", str(self.inspection),
                                 "--declarations", str(self.declarations), "--output", str(self.output),
                                 *extra], text=True, capture_output=True)
        self.assertEqual(ok, result.returncode == 0, result.stderr)
        return result

    def test_additive_routes_only_to_empty_database(self):
        self.write_inspection(); self.write_declaration(); self.run_cli()
        self.assertEqual("PENDING_ADDITIVE_EMPTY", json.loads(self.output.read_text())["outcome"])

    def test_risky_routes_to_populated_upgrade_with_baseline(self):
        self.write_inspection("data-sensitive"); self.write_declaration("data-sensitive")
        self.run_cli("--baseline-source-sha", "a" * 40)
        self.assertEqual("PENDING_POPULATED_UPGRADE", json.loads(self.output.read_text())["outcome"])

    def test_first_risky_migration_is_quarantined(self):
        self.write_inspection("data-sensitive"); self.write_declaration("data-sensitive"); self.run_cli()
        self.assertEqual("QUARANTINED_NO_BASELINE", json.loads(self.output.read_text())["outcome"])

    def test_risky_to_additive_downgrade_is_rejected(self):
        self.write_inspection("data-sensitive"); self.write_declaration("pure-additive")
        self.run_cli(ok=False)

    def test_missing_declaration_fails_closed(self):
        self.write_inspection("data-sensitive"); self.run_cli(ok=False)


if __name__ == "__main__": unittest.main(verbosity=2)
