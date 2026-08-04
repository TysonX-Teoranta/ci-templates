#!/usr/bin/env bash
set -euo pipefail
ROOT="$1" MODE="$2"
COUNT_FILE="$ROOT/$MODE.count"
count=0
[ ! -f "$COUNT_FILE" ] || count=$(cat "$COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" > "$COUNT_FILE"
if [ "$MODE" = infrastructure ] && [ "$count" -eq 1 ]; then
  sleep 30
elif [ "$MODE" = assertion ]; then
  exit 42
else
  printf '<coverage><packages><package><classes><class name="Retry"><lines><line number="1" hits="1"/></lines></class></classes></package></packages></coverage>\n' > "$ROOT/coverage.xml"
fi
