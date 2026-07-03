#!/usr/bin/env bash
# yaml-lint.sh — custom zero-tolerance check: every in-scope .yml/.yaml file must be
# (1) valid YAML and (2) free of tab-indentation / trailing whitespace / missing
# final newline.
#
# Deliberately NOT a full canonical-reformat gate like json-lint.sh: PyYAML's
# load+dump round-trip DROPS EVERY COMMENT and can rewrite quoting/anchors — for
# GH Actions workflow YAML (this repo's own reusable workflows included), comments
# carry load-bearing context (pinned-SHA version notes, hang-timeout postmortems).
# A reformat gate would destroy that on every touch. Validity + whitespace hygiene
# are the safe, unambiguous subset; full YAML pretty-printing is not attempted.
#
# Args: [--report-append <txt>] <file.yml> [file.yaml ...]
# Output: prints the NUMBER OF FAILING FILES to stdout (machine-readable), detail to
# stderr / the appended report. Exit 0 always (the caller decides the verdict).

set -uo pipefail

REPORT=""
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --report-append) REPORT="${2:-}"; shift 2 ;;
    *)               FILES+=("$1"); shift ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "yaml-lint.sh: python3 not found on PATH" >&2; exit 3; }
python3 -c 'import yaml' >/dev/null 2>&1 || { echo "yaml-lint.sh: PyYAML not importable (pip install pyyaml on the runner)" >&2; exit 3; }

emit() {
  # emit <file> <rule> <msg>
  local rel line
  rel=${1#"$(git -C "$(dirname "$1")" rev-parse --show-toplevel 2>/dev/null)"/}
  line="error\t${2}\t${rel:-$1}\t1:1\t${3}"
  printf '%b\n' "$line" >&2
  [ -n "$REPORT" ] && printf '%b\n' "$line" >> "$REPORT"
}

fails=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue

  err="$(python3 -c '
import sys, yaml
try:
    for _ in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
        pass
except Exception as e:
    print(e)
    sys.exit(1)
' "$f" 2>&1)"
  if [ -n "$err" ]; then
    fails=$((fails + 1))
    emit "$f" YAML_INVALID "not valid YAML: ${err//$'\n'/ }"
    continue
  fi

  bad=0
  grep -qP '^\t' "$f" && bad=1                     # YAML spec forbids tab indentation
  grep -qP '[ \t]+$' "$f" && bad=1
  [ -n "$(tail -c1 "$f" 2>/dev/null)" ] && bad=1    # missing trailing newline
  if [ "$bad" = "1" ]; then
    fails=$((fails + 1))
    emit "$f" YAML_WHITESPACE "tab-indentation and/or trailing whitespace and/or missing final newline"
  fi
done

printf '%s\n' "$fails"
exit 0
