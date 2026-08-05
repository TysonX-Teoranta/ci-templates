#!/usr/bin/env python3
"""Disposable acceptance app that performs the Tier 0 database probe contract."""

import http.server
import json
import os
import subprocess


def database_probe() -> dict[str, object]:
    containers = subprocess.run(
        ["docker", "ps", "--filter", "label=tier0.disposable=true", "--format", "{{.Names}}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    if len(containers) != 1:
        raise RuntimeError(f"expected one disposable PostgreSQL container, found {len(containers)}")
    sql = """
BEGIN;
CREATE TEMP TABLE tier0_health_probe (id uuid PRIMARY KEY) ON COMMIT DROP;
INSERT INTO tier0_health_probe VALUES ('00000000-0000-0000-0000-000000000001');
SELECT count(*) FROM tier0_health_probe;
ROLLBACK;
SELECT count(*) FROM \"__EFMigrationsHistory\";
SELECT to_regclass('pg_temp.tier0_health_probe') IS NULL;
"""
    result = subprocess.run(
        ["docker", "exec", containers[0], "psql", "-At", "-v", "ON_ERROR_STOP=1", "-U", "tier0", "-d", "tier0"],
        input=sql,
        check=True,
        capture_output=True,
        text=True,
    )
    values = [line.strip() for line in result.stdout.splitlines() if line.strip() not in {"BEGIN", "CREATE TABLE", "INSERT 0 1", "ROLLBACK"}]
    return {
        "status": "healthy",
        "insertReadBack": values[0] == "1",
        "appliedMigrationCount": int(values[1]),
        "rolledBack": values[2] == "t",
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:  # noqa: N802 - stdlib handler contract
        if self.path != "/tier0/database-probe" or self.headers.get("X-Tier0-Probe-Token") != os.environ["Tier0__DatabaseProbeToken"]:
            self.send_error(403)
            return
        try:
            body = json.dumps(database_probe()).encode()
            self.send_response(200)
        except Exception as error:  # acceptance evidence must retain the concrete probe error
            body = json.dumps({"status": "unhealthy", "error": str(error)}).encode()
            self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


http.server.ThreadingHTTPServer(("127.0.0.1", 18081), Handler).serve_forever()
