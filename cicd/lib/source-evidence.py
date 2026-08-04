#!/usr/bin/env python3
"""Capture and verify fail-closed source/artifact provenance evidence."""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def identity(repo: Path) -> dict[str, str]:
    status = git(repo, "status", "--porcelain=v1", "--untracked-files=all")
    if status:
        raise SystemExit(f"source checkout is modified; refusing evidence:\n{status}")
    return {
        "sourceSha": git(repo, "rev-parse", "HEAD^{commit}"),
        "treeSha": git(repo, "rev-parse", "HEAD^{tree}"),
    }


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_identity(path: Path) -> dict:
    if path.is_symlink() or not path.exists():
        raise SystemExit("artifact is missing or is a symlink")
    if path.is_file():
        return {"path": path.name, "sha256": file_hash(path), "bytes": path.stat().st_size}
    files = []
    for item in sorted(path.rglob("*")):
        if item.is_symlink():
            raise SystemExit(f"artifact contains symlink: {item.relative_to(path)}")
        if item.is_file():
            files.append({"path": item.relative_to(path).as_posix(),
                          "sha256": file_hash(item), "bytes": item.stat().st_size})
    if not files:
        raise SystemExit("artifact directory contains no files")
    aggregate = hashlib.sha256()
    for item in files:
        aggregate.update(json.dumps(item, sort_keys=True, separators=(",", ":")).encode())
        aggregate.update(b"\n")
    return {"path": path.name, "sha256": aggregate.hexdigest(), "files": files}


def capture(args: argparse.Namespace) -> None:
    repo = Path(args.repo).resolve()
    output = Path(args.output).resolve()
    if repo == output or repo in output.parents:
        raise SystemExit("evidence output must be outside the immutable source checkout")
    data = {"schema": 1, **identity(repo)}
    data["testedSourceSha"] = data["sourceSha"]
    data["testedTreeSha"] = data["treeSha"]
    if args.artifact:
        data["artifact"] = artifact_identity(Path(args.artifact).resolve())
        data["artifact"]["sourceSha"] = data["sourceSha"]
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, output)


def verify(args: argparse.Namespace) -> None:
    repo = Path(args.repo).resolve()
    data = json.loads(Path(args.evidence).read_text(encoding="utf-8"))
    current = identity(repo)
    required = {
        "sourceSha": current["sourceSha"], "treeSha": current["treeSha"],
        "testedSourceSha": current["sourceSha"], "testedTreeSha": current["treeSha"],
    }
    for key, expected in required.items():
        if data.get(key) != expected:
            raise SystemExit(f"provenance mismatch: {key}")
    if args.artifact:
        actual = artifact_identity(Path(args.artifact).resolve())
        recorded = data.get("artifact", {})
        if recorded.get("sourceSha") != current["sourceSha"] or recorded.get("sha256") != actual["sha256"]:
            raise SystemExit("artifact provenance mismatch")
    print(current["sourceSha"])


parser = argparse.ArgumentParser()
sub = parser.add_subparsers(dest="command", required=True)
for name in ("capture", "verify"):
    command = sub.add_parser(name)
    command.add_argument("--repo", required=True)
    command.add_argument("--artifact")
    if name == "capture":
        command.add_argument("--output", required=True); command.set_defaults(func=capture)
    else:
        command.add_argument("--evidence", required=True); command.set_defaults(func=verify)
arguments = parser.parse_args()
arguments.func(arguments)
