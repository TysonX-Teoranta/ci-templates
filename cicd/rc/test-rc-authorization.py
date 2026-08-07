#!/usr/bin/env python3
import base64
import hashlib
import hmac
import os
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("rc-authorization.py")
NOW = 1_800_000_000
SECRET = base64.b32encode(b"tier0-test-totp-key").decode().rstrip("=")


def code(at=NOW, algorithm="sha1", period=30):
    key = base64.b32decode(SECRET + "=" * (-len(SECRET) % 8))
    digest = hmac.new(key, struct.pack(">Q", at // period), getattr(hashlib, algorithm)).digest()
    offset = digest[-1] & 15
    return f"{(struct.unpack('>I', digest[offset:offset+4])[0] & 0x7fffffff) % 1000000:06d}"


class AuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = str(Path(self.temp.name) / "state.sqlite3")
        self.env = os.environ | {
            "TIER0_TOTP_SECRET": SECRET,
            "TIER0_AUTH_SIGNING_KEY": "test-only-signing-key",
        }

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *args, ok=True):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--store", self.store, *map(str, args)],
            text=True, capture_output=True, env=self.env,
        )
        if ok and result.returncode:
            self.fail(result.stderr)
        if not ok and not result.returncode:
            self.fail(f"unexpected success: {result.stdout}")
        return result

    def issue(self, domain="lodgers", actor="lodgings-ie", now=NOW, ttl=180):
        return self.run_cli("issue", "--domain", domain, "--actor", actor,
                            "--totp", code(now), "--now", now, "--ttl", ttl).stdout.strip()

    def claim(self, auth, domain="lodgers", actor="lodgings-ie", now=NOW, ok=False):
        return self.run_cli("claim", "--authorization-id", auth, "--domain", domain,
                            "--actor", actor, "--now", now, ok=ok)

    def test_invalid_totp_is_rejected(self):
        result = self.run_cli("issue", "--domain", "lodgers", "--actor", "lodgings-ie",
                              "--totp", "000000", "--now", NOW, ok=False)
        self.assertIn("TOTP rejected", result.stderr)

    def test_standard_authenticator_algorithms_are_accepted(self):
        for offset, algorithm in enumerate(("sha1", "sha256", "sha512")):
            now = NOW + offset * 90
            result = self.run_cli(
                "issue", "--domain", "lodgers", "--actor", "lodgings-ie",
                "--totp", code(now, algorithm), "--now", now,
            )
            self.assertTrue(result.stdout.startswith("t0_"), algorithm)

    def test_sixty_second_authenticator_period_is_accepted(self):
        result = self.run_cli(
            "issue", "--domain", "lodgers", "--actor", "lodgings-ie",
            "--totp", code(NOW, period=60), "--now", NOW,
        )
        self.assertTrue(result.stdout.startswith("t0_"))

    def test_matching_seed_reports_counter_drift_without_accepting(self):
        result = self.run_cli(
            "issue", "--domain", "lodgers", "--actor", "lodgings-ie",
            "--totp", code(NOW + 5 * 30), "--now", NOW, ok=False,
        )
        self.assertIn("counter drift of 5 x 30 seconds", result.stderr)

    def test_rfc6238_vectors_are_independent_of_cli(self):
        module = __import__("runpy").run_path(str(SCRIPT))
        vectors = {
            "SHA1": (b"12345678901234567890", "94287082"),
            "SHA256": (b"12345678901234567890123456789012", "46119246"),
            "SHA512": (b"1234567890123456789012345678901234567890123456789012345678901234", "90693936"),
        }
        for algorithm, (raw_secret, expected) in vectors.items():
            encoded = base64.b32encode(raw_secret).decode().rstrip("=")
            actual = module["totp"](encoded, 59, algorithm=algorithm, digits=8)
            self.assertEqual(expected, actual, algorithm)

    def test_unauthorized_actor_is_rejected(self):
        result = self.run_cli("issue", "--domain", "lodgers", "--actor", "attacker",
                              "--totp", code(), "--now", NOW, ok=False)
        self.assertIn("actor is not authorized", result.stderr)

    def test_expired_and_direct_dispatch_are_rejected(self):
        auth = self.issue(ttl=30)
        self.assertIn("expired", self.claim(auth, now=NOW + 31).stderr)
        missing = self.claim("not-an-authorization", now=NOW, )
        self.assertNotEqual(missing.returncode, 0)

    def test_replay_is_rejected(self):
        auth = self.issue()
        lifecycle = self.claim(auth, ok=True).stdout.strip()
        self.assertTrue(lifecycle)
        self.assertIn("already consumed", self.claim(auth).stderr)

    def test_simultaneous_claim_has_exactly_one_winner(self):
        auth = self.issue()
        command = [sys.executable, str(SCRIPT), "--store", self.store, "claim",
                   "--authorization-id", auth, "--domain", "lodgers",
                   "--actor", "lodgings-ie", "--now", str(NOW)]
        attempts = [subprocess.Popen(command, text=True, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=self.env) for _ in range(8)]
        results = [process.communicate() + (process.returncode,) for process in attempts]
        self.assertEqual(1, sum(returncode == 0 for _, _, returncode in results))

    def test_singleton_collision_is_rejected(self):
        first = self.issue()
        self.claim(first, ok=True)
        second = self.issue(now=NOW + 30)
        result = self.claim(second, now=NOW + 30)
        self.assertIn("singleton collision", result.stderr)

    def test_stale_recovery_is_explicit_and_audited(self):
        auth = self.issue()
        lifecycle = self.claim(auth, ok=True).stdout.strip()
        fresh = self.run_cli("recover", "--lifecycle-id", lifecycle, "--operator", "ops",
                             "--reason", "verified abandoned runner", "--now", NOW + 899,
                             ok=False)
        self.assertIn("not stale", fresh.stderr)
        self.run_cli("recover", "--lifecycle-id", lifecycle, "--operator", "ops",
                     "--reason", "verified abandoned runner", "--now", NOW + 901)
        db = sqlite3.connect(self.store)
        state, reason = db.execute(
            "SELECT state,recovery_reason FROM lifecycles WHERE id=?", (lifecycle,)
        ).fetchone()
        events = db.execute("SELECT event FROM audit WHERE lifecycle_id=?", (lifecycle,)).fetchall()
        self.assertEqual(("recovered", "verified abandoned runner"), (state, reason))
        self.assertIn(("lifecycle_recovered",), events)

    def test_tampered_record_is_rejected(self):
        auth = self.issue()
        db = sqlite3.connect(self.store)
        db.execute("UPDATE authorizations SET actor='attacker' WHERE id=?", (auth,))
        db.commit()
        result = self.claim(auth, actor="attacker")
        self.assertIn("signature mismatch", result.stderr)

    def test_status_reports_latest_lifecycle_and_can_require_terminal_state(self):
        auth = self.issue()
        lifecycle = self.claim(auth, ok=True).stdout.strip()
        building = self.run_cli("status", "--domain", "lodgers")
        self.assertEqual(lifecycle, __import__("json").loads(building.stdout)["id"])
        self.assertIn("got building", self.run_cli(
            "status", "--domain", "lodgers", "--lifecycle-id", lifecycle,
            "--expect-state", "complete", ok=False,
        ).stderr)
        self.run_cli("lifecycle", "activate", "--lifecycle-id", lifecycle,
                     "--actor", "lodgings-ie", "--now", NOW + 1)
        self.run_cli("lifecycle", "complete", "--lifecycle-id", lifecycle,
                     "--actor", "lodgings-ie", "--now", NOW + 2)
        complete = self.run_cli(
            "status", "--domain", "lodgers", "--lifecycle-id", lifecycle,
            "--expect-state", "complete",
        )
        self.assertEqual("complete", __import__("json").loads(complete.stdout)["state"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
