#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("source-evidence.py")


class SourceEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "test"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "test@example.invalid"], check=True)
        (self.repo / "source.txt").write_text("source\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "source.txt"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "fixture"], check=True)
        self.artifact = self.root / "artifact"
        self.artifact.mkdir()
        (self.artifact / "app.dll").write_bytes(b"binary")
        self.evidence = self.root / "evidence.json"

    def tearDown(self): self.temp.cleanup()

    def run_cli(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], text=True,
                                capture_output=True)
        self.assertEqual(ok, result.returncode == 0, result.stderr)
        return result

    def capture(self):
        self.run_cli("capture", "--repo", self.repo, "--artifact", self.artifact,
                     "--output", self.evidence)

    def test_exact_source_tree_and_artifact_are_bound(self):
        self.capture()
        data = json.loads(self.evidence.read_text())
        self.assertEqual(data["sourceSha"], data["testedSourceSha"])
        self.assertEqual(data["treeSha"], data["testedTreeSha"])
        self.assertEqual(data["sourceSha"], data["artifact"]["sourceSha"])
        self.run_cli("verify", "--repo", self.repo, "--artifact", self.artifact,
                     "--evidence", self.evidence)

    def test_source_change_fails_closed(self):
        self.capture()
        (self.repo / "source.txt").write_text("changed\n")
        self.run_cli("verify", "--repo", self.repo, "--artifact", self.artifact,
                     "--evidence", self.evidence, ok=False)

    def test_ignored_output_is_distinguished_from_source_change(self):
        (self.repo / ".gitignore").write_text("bin/\n")
        subprocess.run(["git", "-C", str(self.repo), "add", ".gitignore"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "ignore output"], check=True)
        (self.repo / "bin").mkdir(); (self.repo / "bin/app.dll").write_bytes(b"ignored")
        self.capture()

    def test_artifact_change_fails_closed(self):
        self.capture()
        (self.artifact / "app.dll").write_bytes(b"tampered")
        self.run_cli("verify", "--repo", self.repo, "--artifact", self.artifact,
                     "--evidence", self.evidence, ok=False)

    def test_named_infrastructure_checkout_is_the_only_allowed_untracked_tree(self):
        spine = self.repo / ".ci-templates"
        spine.mkdir()
        (spine / "spine.sh").write_text("#!/bin/sh\n")
        self.run_cli("capture", "--repo", self.repo, "--artifact", self.artifact,
                     "--output", self.evidence, ok=False)
        self.run_cli("capture", "--repo", self.repo, "--artifact", self.artifact,
                     "--output", self.evidence, "--allow-untracked", ".ci-templates")
        (self.repo / "unexpected.txt").write_text("not infrastructure\n")
        self.run_cli("verify", "--repo", self.repo, "--artifact", self.artifact,
                     "--evidence", self.evidence, "--allow-untracked", ".ci-templates", ok=False)


if __name__ == "__main__": unittest.main(verbosity=2)
