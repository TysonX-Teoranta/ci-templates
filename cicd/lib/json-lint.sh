#!/usr/bin/env bash
# json-lint.sh — custom zero-tolerance check: every in-scope .json file must be
# (1) syntactically valid JSON and (2) formatted to a canonical indent (default 2
# spaces, jq's own re-serialization — no key reordering, so it never fights a repo's
# existing key order, only whitespace/indent drift).
#
# Deterministic, no dotnet/analyzer dependency — just jq. A file with invalid JSON
# always fails (and skips the formatting check, since there is no canonical form of
# broken JSON). A syntactically valid file that doesn't match its own canonical
# re-serialization fails formatting.
#
# JSONC exception: ASP.NET appsettings*.json (and explicit *.jsonc) officially
# support // and /* */ comments (Microsoft.Extensions.Configuration.Json reads with
# JsonCommentHandling.Skip), and those comments carry real documentation value —
# the same ethos as the comment-density check. For these files validity is checked
# AFTER a comment strip, and the canonical-format check is skipped (a jq rewrite
# would destroy the comments). Trailing commas stay findings even though ASP.NET
# tolerates them — the gate is allowed to be stricter than the runtime.
#
# Args: [--report-append <txt>] [--indent N] <file.json> [file.json ...]
# Output: prints the NUMBER OF FAILING FILES to stdout (machine-readable), detail to
# stderr / the appended report. Exit 0 always (the caller decides the verdict).

set -uo pipefail

INDENT="${CICD_JSON_INDENT:-2}"
REPORT=""
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --report-append) REPORT="${2:-}"; shift 2 ;;
    --indent)        INDENT="${2:-}"; shift 2 ;;
    *)               FILES+=("$1"); shift ;;
  esac
done

emit() {
  # emit <file> <rule> <msg>
  local rel line
  rel=${1#"$(git -C "$(dirname "$1")" rev-parse --show-toplevel 2>/dev/null)"/}
  line="error\t${2}\t${rel:-$1}\t1:1\t${3}"
  printf '%b\n' "$line" >&2
  [ -n "$REPORT" ] && printf '%b\n' "$line" >> "$REPORT"
}

# is_jsonc <file> — files whose consumer officially reads JSON-with-comments.
is_jsonc() {
  case "$(basename "$1")" in
    appsettings.json|appsettings.*.json|*.jsonc) return 0 ;;
    *) return 1 ;;
  esac
}

# strip_jsonc <file> — remove // and /* */ comments, string-aware (a "//" inside a
# JSON string is content, not a comment). Character scanner, plain awk, no deps.
strip_jsonc() {
  awk '
    BEGIN { instr = 0; esc = 0; blockc = 0 }
    {
      line = $0; n = length(line); out = ""; linec = 0
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        nx = (i < n) ? substr(line, i + 1, 1) : ""
        if (linec) break
        if (blockc) { if (c == "*" && nx == "/") { blockc = 0; i++ }; continue }
        if (instr) {
          out = out c
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") instr = 0
          continue
        }
        if (c == "/" && nx == "/") { linec = 1; i++; continue }
        if (c == "/" && nx == "*") { blockc = 1; i++; continue }
        if (c == "\"") instr = 1
        out = out c
      }
      print out
    }
  ' "$1"
}

fails=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue

  # JSONC consumers: validate with comments stripped; skip the canonical-format
  # check (a jq re-serialization would delete the comments it is allowed to have).
  if is_jsonc "$f"; then
    err="$(strip_jsonc "$f" | jq empty 2>&1 1>/dev/null)"
    if [ -n "$err" ]; then
      fails=$((fails + 1))
      emit "$f" JSON_INVALID "not valid JSONC (checked with comments stripped): ${err//$'\n'/ }"
    fi
    continue
  fi

  err="$(jq empty "$f" 2>&1 1>/dev/null)"
  if [ -n "$err" ]; then
    fails=$((fails + 1))
    emit "$f" JSON_INVALID "not valid JSON: ${err//$'\n'/ }"
    continue
  fi

  canon="$(jq --indent "$INDENT" . "$f" 2>/dev/null)"
  actual="$(cat "$f")"
  if [ "$canon" != "$actual" ]; then
    fails=$((fails + 1))
    emit "$f" JSON_FORMAT "not canonically formatted (expected jq --indent ${INDENT} .)"
  fi
done

printf '%s\n' "$fails"
exit 0
