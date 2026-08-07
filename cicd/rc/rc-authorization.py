#!/usr/bin/env python3
"""Durable, transactional TOTP authorization and singleton lifecycle boundary."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import struct
import subprocess
import sys
import time
from pathlib import Path


def fail(message: str) -> None:
    print(f"rc-authorization: {message}", file=sys.stderr)
    raise SystemExit(1)


def connect(path: str) -> sqlite3.Connection:
    Path(path).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS authorizations (
          id TEXT PRIMARY KEY, domain TEXT NOT NULL, actor TEXT NOT NULL,
          nonce_hash TEXT NOT NULL UNIQUE, issued_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL, signature TEXT NOT NULL,
          consumed_at INTEGER, lifecycle_id TEXT
        );
        CREATE TABLE IF NOT EXISTS lifecycles (
          id TEXT PRIMARY KEY, domain TEXT NOT NULL, state TEXT NOT NULL,
          authorization_id TEXT NOT NULL, actor TEXT NOT NULL,
          created_at INTEGER NOT NULL, last_heartbeat INTEGER NOT NULL,
          ended_at INTEGER, recovery_reason TEXT,
          FOREIGN KEY (authorization_id) REFERENCES authorizations(id)
        );
        CREATE UNIQUE INDEX IF NOT EXISTS one_active_lifecycle_per_domain
          ON lifecycles(domain) WHERE state IN ('building', 'active');
        CREATE TABLE IF NOT EXISTS audit (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at INTEGER NOT NULL,
          event TEXT NOT NULL, domain TEXT, actor TEXT, authorization_id TEXT,
          lifecycle_id TEXT, detail TEXT NOT NULL DEFAULT ''
        );
        """
    )
    return db


def secret_value(name: str, path: str) -> str:
    value = os.environ.get(name, "")
    if not value and Path(path).is_file():
        value = Path(path).read_text(encoding="utf-8").strip()
    if not value:
        fail(f"{name} or {path} is required")
    return value


TOTP_DIGESTS = {
    "SHA1": hashlib.sha1,
    "SHA256": hashlib.sha256,
    "SHA512": hashlib.sha512,
}


def totp(secret: str, at: int, *, algorithm: str = "SHA1", digits: int = 6,
         period: int = 30) -> str:
    try:
        key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8), casefold=True)
    except Exception:
        fail("invalid TOTP secret encoding")
    try:
        digestmod = TOTP_DIGESTS[algorithm.upper()]
    except KeyError:
        fail(f"unsupported TOTP algorithm: {algorithm}")
    if digits not in (6, 8) or period not in (30, 60):
        fail("unsupported TOTP digits or period")
    counter = at // period
    digest = hmac.new(key, struct.pack(">Q", counter), digestmod).digest()
    offset = digest[-1] & 0x0F
    modulus = 10 ** digits
    value = (struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF) % modulus
    return f"{value:0{digits}d}"


def find_totp_match(secret: str, supplied: str, now: int,
                    algorithms: tuple[str, ...], periods: tuple[int, ...],
                    window: int) -> tuple[str, int, int] | None:
    if not supplied.isdigit() or len(supplied) != 6:
        return None
    for algorithm in algorithms:
        for period in periods:
            for drift_steps in range(-window, window + 1):
                if hmac.compare_digest(
                    supplied,
                    totp(secret, now + drift_steps * period,
                         algorithm=algorithm, period=period),
                ):
                    return algorithm, period, drift_steps
    return None


def configured_totp_algorithms() -> tuple[str, ...]:
    raw = os.environ.get("TIER0_TOTP_ALGORITHMS", "")
    if not raw:
        try:
            raw = Path("/etc/tier0/totp-algorithms").read_text(encoding="utf-8").strip()
        except (FileNotFoundError, PermissionError):
            raw = "SHA1,SHA256,SHA512"
    algorithms = tuple(item.strip().upper() for item in raw.split(",") if item.strip())
    if not algorithms or any(item not in TOTP_DIGESTS for item in algorithms):
        fail("invalid configured TOTP algorithm list")
    return algorithms


def configured_totp_periods() -> tuple[int, ...]:
    raw = os.environ.get("TIER0_TOTP_PERIODS", "30,60")
    try:
        periods = tuple(int(item.strip()) for item in raw.split(",") if item.strip())
    except ValueError:
        fail("invalid configured TOTP period list")
    if not periods or any(item not in (30, 60) for item in periods):
        fail("invalid configured TOTP period list")
    return periods


def signature(key: str, auth_id: str, domain: str, actor: str, nonce_hash: str,
              issued: int, expires: int) -> str:
    body = "\0".join((auth_id, domain, actor, nonce_hash, str(issued), str(expires)))
    return hmac.new(key.encode(), body.encode(), hashlib.sha256).hexdigest()


def audit(db: sqlite3.Connection, event: str, now: int, *, domain: str = "",
          actor: str = "", auth_id: str = "", lifecycle_id: str = "",
          detail: str = "") -> None:
    db.execute(
        "INSERT INTO audit(occurred_at,event,domain,actor,authorization_id,lifecycle_id,detail) "
        "VALUES(?,?,?,?,?,?,?)",
        (now, event, domain or None, actor or None, auth_id or None,
         lifecycle_id or None, detail),
    )


def issue(args: argparse.Namespace) -> None:
    now = args.now or int(time.time())
    if args.actor != args.allowed_actor:
        fail("actor is not authorized to create a devRC")
    db = connect(args.store)
    recent_failures = db.execute(
        "SELECT count(*) FROM audit WHERE event='authorization_rejected' AND actor=? AND occurred_at>?",
        (args.actor, now - 300),
    ).fetchone()[0]
    if recent_failures >= 5:
        fail("TOTP gateway rate limit exceeded")
    supplied_totp = sys.stdin.readline().strip() if args.totp_stdin else (args.totp or "")
    totp_secret = secret_value("TIER0_TOTP_SECRET", "/etc/tier0/totp-secret")
    totp_algorithms = configured_totp_algorithms()
    totp_periods = configured_totp_periods()
    matched_totp = find_totp_match(
        totp_secret,
        supplied_totp,
        now,
        totp_algorithms,
        totp_periods,
        1,
    )
    if matched_totp is None:
        drift_match = find_totp_match(
            totp_secret, supplied_totp, now, totp_algorithms, totp_periods, 20,
        )
        with db:
            audit(db, "authorization_rejected", now, domain=args.domain, actor=args.actor,
                  detail="invalid_totp" if drift_match is None else
                  f"totp_counter_drift={drift_match[2]};period={drift_match[1]};algorithm={drift_match[0]}")
        if drift_match is not None:
            fail(f"TOTP rejected: matching seed has counter drift of {drift_match[2]} "
                 f"x {drift_match[1]} seconds")
        fail("TOTP rejected: no match for the installed seed across supported algorithms and periods")
    matched_algorithm, matched_period, _ = matched_totp
    if args.ttl < 30 or args.ttl > 600:
        fail("authorization TTL must be between 30 and 600 seconds")
    # The stable prefix prevents an opaque value beginning with "-" from being
    # interpreted as an argparse option by any downstream shell boundary.
    auth_id = "t0_" + secrets.token_urlsafe(24)
    nonce_hash = hashlib.sha256(secrets.token_bytes(32)).hexdigest()
    expires = now + args.ttl
    sig = signature(secret_value("TIER0_AUTH_SIGNING_KEY", "/etc/tier0/auth-signing-key"), auth_id, args.domain,
                    args.actor, nonce_hash, now, expires)
    with db:
        db.execute(
            "INSERT INTO authorizations VALUES(?,?,?,?,?,?,?,?,NULL)",
            (auth_id, args.domain, args.actor, nonce_hash, now, expires, sig, None),
        )
        audit(db, "authorization_issued", now, domain=args.domain, actor=args.actor,
              auth_id=auth_id,
              detail=f"totp_algorithm={matched_algorithm};totp_period={matched_period}")
    print(auth_id)
    if args.dispatch_repo:
        command = ["/usr/sbin/runuser", "-u", "tysonxpulse", "--", "/usr/bin/env",
                   "HOME=/home/deploy", "GH_CONFIG_DIR=/home/deploy/.config/gh",
                   "gh", "workflow", "run", args.workflow, "-R", args.dispatch_repo,
                   "--ref", args.ref, "-f", f"authorization_id={auth_id}"]
        subprocess.run(command, check=True)


def claim(args: argparse.Namespace) -> None:
    now = args.now or int(time.time())
    db = connect(args.store)
    try:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT * FROM authorizations WHERE id=?", (args.authorization_id,)).fetchone()
        if row is None:
            fail("authorization record not found")
        expected = signature(secret_value("TIER0_AUTH_SIGNING_KEY", "/etc/tier0/auth-signing-key"), row["id"], row["domain"],
                             row["actor"], row["nonce_hash"], row["issued_at"], row["expires_at"])
        if not hmac.compare_digest(expected, row["signature"]):
            fail("authorization signature mismatch")
        if row["domain"] != args.domain or row["actor"] != args.actor:
            fail("authorization scope mismatch")
        if row["consumed_at"] is not None:
            fail("authorization already consumed")
        if now > row["expires_at"]:
            fail("authorization expired")
        existing = db.execute(
            "SELECT id,state,last_heartbeat FROM lifecycles "
            "WHERE domain=? AND state IN ('building','active')", (args.domain,)
        ).fetchone()
        if existing:
            age = now - existing["last_heartbeat"]
            fail(f"singleton collision: lifecycle={existing['id']} state={existing['state']} heartbeat_age={age}s")
        lifecycle_id = "lc_" + secrets.token_urlsafe(18)
        db.execute(
            "INSERT INTO lifecycles VALUES(?,?,?,?,?,?,?,NULL,NULL)",
            (lifecycle_id, args.domain, "building", row["id"], row["actor"], now, now),
        )
        updated = db.execute(
            "UPDATE authorizations SET consumed_at=?,lifecycle_id=? WHERE id=? AND consumed_at IS NULL",
            (now, lifecycle_id, row["id"]),
        ).rowcount
        if updated != 1:
            fail("authorization claim lost")
        audit(db, "authorization_claimed", now, domain=args.domain, actor=args.actor,
              auth_id=row["id"], lifecycle_id=lifecycle_id)
        db.commit()
    except BaseException:
        db.rollback()
        raise
    print(lifecycle_id)


def lifecycle(args: argparse.Namespace) -> None:
    now = args.now or int(time.time())
    db = connect(args.store)
    with db:
        row = db.execute("SELECT * FROM lifecycles WHERE id=?", (args.lifecycle_id,)).fetchone()
        if row is None:
            fail("lifecycle not found")
        if args.action == "heartbeat":
            if row["state"] not in ("building", "active"):
                fail("cannot heartbeat terminal lifecycle")
            db.execute("UPDATE lifecycles SET last_heartbeat=? WHERE id=?", (now, args.lifecycle_id))
        else:
            allowed = {"activate": ("building", "active"), "complete": ("active", "complete"),
                       "fail": (("building", "active"), "failed")}
            source, target = allowed[args.action]
            sources = source if isinstance(source, tuple) else (source,)
            if row["state"] not in sources:
                fail(f"invalid lifecycle transition {row['state']} -> {target}")
            ended = now if target in ("complete", "failed") else None
            db.execute("UPDATE lifecycles SET state=?,last_heartbeat=?,ended_at=? WHERE id=?",
                       (target, now, ended, args.lifecycle_id))
        audit(db, f"lifecycle_{args.action}", now, domain=row["domain"], actor=args.actor,
              auth_id=row["authorization_id"], lifecycle_id=args.lifecycle_id)


def recover(args: argparse.Namespace) -> None:
    now = args.now or int(time.time())
    if not args.reason.strip():
        fail("operator recovery reason is required")
    db = connect(args.store)
    with db:
        row = db.execute("SELECT * FROM lifecycles WHERE id=?", (args.lifecycle_id,)).fetchone()
        if row is None or row["state"] != "building":
            fail("only a building lifecycle can be recovered")
        age = now - row["last_heartbeat"]
        if age < args.stale_after:
            fail(f"lifecycle is not stale: heartbeat_age={age}s")
        db.execute(
            "UPDATE lifecycles SET state='recovered',ended_at=?,recovery_reason=? WHERE id=?",
            (now, args.reason, args.lifecycle_id),
        )
        audit(db, "lifecycle_recovered", now, domain=row["domain"], actor=args.operator,
              auth_id=row["authorization_id"], lifecycle_id=args.lifecycle_id,
              detail=args.reason)


def initialize(args: argparse.Namespace) -> None:
    connect(args.store).close()


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("--store", default=os.environ.get("TIER0_AUTH_STORE", "/var/lib/tier0/rc-authorizations.sqlite3"))
    sub = p.add_subparsers(dest="command", required=True)
    initial = sub.add_parser("init"); initial.set_defaults(func=initialize)
    i = sub.add_parser("issue")
    i.add_argument("--domain", required=True); i.add_argument("--actor", required=True)
    i.add_argument("--allowed-actor", default="lodgings-ie")
    totp_input = i.add_mutually_exclusive_group(required=True)
    totp_input.add_argument("--totp"); totp_input.add_argument("--totp-stdin", action="store_true")
    i.add_argument("--ttl", type=int, default=180)
    i.add_argument("--now", type=int); i.add_argument("--dispatch-repo")
    i.add_argument("--workflow", default="finalise-rc.yml"); i.add_argument("--ref", default="lodgers-dev")
    i.set_defaults(func=issue)
    c = sub.add_parser("claim")
    c.add_argument("--authorization-id", required=True); c.add_argument("--domain", required=True)
    c.add_argument("--actor", required=True); c.add_argument("--now", type=int); c.set_defaults(func=claim)
    l = sub.add_parser("lifecycle")
    l.add_argument("action", choices=("heartbeat", "activate", "complete", "fail"))
    l.add_argument("--lifecycle-id", required=True); l.add_argument("--actor", required=True)
    l.add_argument("--now", type=int); l.set_defaults(func=lifecycle)
    r = sub.add_parser("recover")
    r.add_argument("--lifecycle-id", required=True); r.add_argument("--operator", required=True)
    r.add_argument("--reason", required=True); r.add_argument("--stale-after", type=int, default=900)
    r.add_argument("--now", type=int); r.set_defaults(func=recover)
    return p


if __name__ == "__main__":
    arguments = parser().parse_args()
    arguments.func(arguments)
