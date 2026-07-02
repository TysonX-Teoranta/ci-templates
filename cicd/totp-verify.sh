#!/usr/bin/env bash
# totp-verify.sh — CICD v2 external live-release TOTP gate (contract C178289477824693).
# The SECOND, structural live gate: after GitHub's Environment 'live' email-approval,
# the live pull-agent (OUR spine, off GitHub) blocks here until Crom's live TOTP is
# verified against the CROM-PRIVATE seed — a seed GitHub never holds, so no GitHub
# actor or AI can satisfy this gate (blast radius independent of model/GitHub).
# Deterministic: oathtool recomputes the expected code and validates by exit status;
# zero AI at runtime. Never prints the seed or the candidate code.
# Fleet V3: strict mode, header, -v verbose, --dry-run, offline-testable.

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

show_help() {
  cat <<'EOF'
totp-verify.sh — verify Crom's live-release TOTP against the CROM-PRIVATE seed.

Usage:
  totp-verify.sh --code <NNNNNN> [--seed-file <path>] [--window <n>] [-v] [--dry-run]
  totp-verify.sh --help

Seed (CROM-PRIVATE — never in the repo, never in GitHub):
  Resolved in order:
    1. --seed-file <path>
    2. $CICD_TOTP_SEED_FILE   (a base32 seed file, mode 600, provisioned out-of-band
                               on the spine only)
  This script reads the seed but never prints it.

Code (ephemeral, single-use):
  --code <NNNNNN>   the 6-digit TOTP Crom read from his authenticator
                    (falls back to $CICD_TOTP_CODE when --code is omitted)

Options:
  --window <n>   accept the code within +/- n 30s steps for clock skew (default 1)
  --dry-run      validate plumbing (oathtool present, seed readable, code well-formed)
                 but do NOT compare — always exits 0 without asserting a match

Exit: 0 verified (or dry-run) · 1 mismatch/expired · 2 usage · 3 missing tool
      4 seed unavailable · 5 code not provided
EOF
}

# --- Defaults ----------------------------------------------------------------
CODE=""
SEED_FILE_ARG=""
WINDOW=1

# --- Parse -------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --code)      [ $# -ge 2 ] || { err "--code needs a value"; exit 2; };      CODE="$2"; shift 2 ;;
    --seed-file) [ $# -ge 2 ] || { err "--seed-file needs a value"; exit 2; }; SEED_FILE_ARG="$2"; shift 2 ;;
    --window)    [ $# -ge 2 ] || { err "--window needs a value"; exit 2; };    WINDOW="$2"; shift 2 ;;
    -v|--verbose) CICD_VERBOSE=1; shift ;;
    --dry-run)    CICD_DRY_RUN=1; shift ;;
    -h|--help)    show_help; exit 0 ;;
    *) err "unknown argument: $1 — see --help"; exit 2 ;;
  esac
done

require oathtool

# --- Resolve + validate the candidate code (never logged) --------------------
[ -n "$CODE" ] || CODE="${CICD_TOTP_CODE:-}"
[ -n "$CODE" ] || die "no TOTP code: pass --code <NNNNNN> or set CICD_TOTP_CODE" 5
case "$CODE" in
  *[!0-9]*) err "TOTP code must be digits only"; exit 2 ;;
esac
[ "${#CODE}" -ge 6 ] || die "TOTP code too short (expected at least 6 digits)" 2

# --- Validate the window -----------------------------------------------------
case "$WINDOW" in
  ''|*[!0-9]*) err "--window must be a non-negative integer"; exit 2 ;;
esac

# --- Resolve + read the CROM-PRIVATE seed (never logged) ----------------------
SEED_FILE="$SEED_FILE_ARG"
[ -n "$SEED_FILE" ] || SEED_FILE="${CICD_TOTP_SEED_FILE:-}"
[ -n "$SEED_FILE" ] || die "no seed source: pass --seed-file or set CICD_TOTP_SEED_FILE (CROM-PRIVATE seed, off GitHub)" 4
[ -f "$SEED_FILE" ] || die "seed file not found: $SEED_FILE (CROM-PRIVATE, provisioned out-of-band on the spine)" 4
[ -r "$SEED_FILE" ] || die "seed file not readable: $SEED_FILE" 4

SEED="$(tr -d ' \t\r\n' < "$SEED_FILE")"
[ -n "$SEED" ] || die "seed file is empty: $SEED_FILE" 4

# --- Dry-run: plumbing proven, no assertion ----------------------------------
if [ "${CICD_DRY_RUN:-0}" = "1" ]; then
  log "[dry-run] plumbing OK: oathtool present, seed readable ($SEED_FILE), code well-formed — NOT asserting a match"
  exit 0
fi

# --- Verify ------------------------------------------------------------------
# oathtool validates when given the OTP as a second positional: exit 0 iff CODE is
# the TOTP for SEED within +/-WINDOW steps. All output is suppressed so neither the
# seed, the code, nor the counter range leaks to CI logs.
if oathtool --totp -b -w "$WINDOW" "$SEED" "$CODE" >/dev/null 2>&1; then
  log "live TOTP verified — external release gate satisfied"
  exit 0
fi

err "live TOTP verification FAILED — code did not match within +/-${WINDOW} step(s); live release BLOCKED"
exit 1
