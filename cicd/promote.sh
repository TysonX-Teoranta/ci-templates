#!/usr/bin/env bash
# promote.sh — CICD v2 promotion signal emitter (contract C178289477824693).
# Emits the deterministic "approved-release" signal for one env AFTER that env's
# structural gate has passed (GH Environment email-approval for staging; GH Env
# protection + external TOTP for live — see totp-verify.sh). Writes a release
# manifest to a signal location the env's pull-agent polls; it does NOT deploy and
# never touches env creds (the pull-agent does that off GitHub). Zero AI at runtime.
# Fleet V3: strict mode, header, -v verbose, --dry-run, offline-testable.

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

show_help() {
  cat <<'EOF'
promote.sh — emit the approved-release signal for a promotion target env.

Usage:
  promote.sh <env> --domain <name> [--ref <git-sha>] [--artifact <ref>]
             [--signal-dir <dir>] [-v] [--dry-run]
  promote.sh --help

Positional:
  <env>   promotion target: 'staging' or 'live' (the only valid targets).

Options:
  --domain <name>   domains.yml key this release is for (validated against the registry)
  --ref <git-sha>   the exact commit being promoted (default: current HEAD if in a repo)
  --artifact <ref>  signed-artifact reference (registry/bucket id) being released
  --signal-dir <d>  where to write the release manifest (default: $CICD_SIGNAL_DIR
                    or cicd/reports/signals)

Behaviour:
  Writes <signal-dir>/<domain>-<env>-release.json — the approved-release manifest the
  env pull-agent polls. This is the SIGNAL only; live still blocks on totp-verify.sh
  before the pull-agent applies. Never deploys, never holds env creds.

Exit: 0 emitted/dry-run · 2 usage · 3 missing tool/registry/domain
EOF
}

# --- Defaults ----------------------------------------------------------------
ENV_TARGET=""
DOMAIN=""
REF=""
ARTIFACT=""
SIGNAL_DIR="${CICD_SIGNAL_DIR:-$CICD_ROOT/reports/signals}"

# --- Parse -------------------------------------------------------------------
[ $# -gt 0 ] || { err "missing <env> (staging|live) — see --help"; exit 2; }
case "$1" in
  -h|--help) show_help; exit 0 ;;
  -*) err "first argument must be the target env (staging|live), not an option"; exit 2 ;;
  *)  ENV_TARGET="$1"; shift ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)     [ $# -ge 2 ] || { err "--domain needs a value"; exit 2; };     DOMAIN="$2"; shift 2 ;;
    --ref)        [ $# -ge 2 ] || { err "--ref needs a value"; exit 2; };        REF="$2"; shift 2 ;;
    --artifact)   [ $# -ge 2 ] || { err "--artifact needs a value"; exit 2; };   ARTIFACT="$2"; shift 2 ;;
    --signal-dir) [ $# -ge 2 ] || { err "--signal-dir needs a value"; exit 2; }; SIGNAL_DIR="$2"; shift 2 ;;
    -v|--verbose) CICD_VERBOSE=1; shift ;;
    --dry-run)    CICD_DRY_RUN=1; shift ;;
    -h|--help)    show_help; exit 0 ;;
    *) err "unknown argument: $1 — see --help"; exit 2 ;;
  esac
done

# --- Validate ----------------------------------------------------------------
case "$ENV_TARGET" in
  staging|live) : ;;
  *) err "invalid env '$ENV_TARGET' (valid: staging, live)"; exit 2 ;;
esac

[ -n "$DOMAIN" ] || { err "--domain is required (a domains.yml key)"; exit 2; }
domain_exists "$DOMAIN" || die "domain not in registry ($REGISTRY): $DOMAIN" 3

# Default the promoted ref to the current commit when run inside a checkout.
if [ -z "$REF" ]; then
  if have git && git rev-parse --git-dir >/dev/null 2>&1; then
    REF="$(git rev-parse HEAD 2>/dev/null || true)"
  fi
fi
[ -n "$REF" ] || REF="unknown"

# --- Emit --------------------------------------------------------------------
APPROVED_AT="$(_ts)"
MANIFEST_PATH="$SIGNAL_DIR/${DOMAIN}-${ENV_TARGET}-release.json"

# Live carries a second, external gate (totp-verify.sh) the pull-agent must clear
# before apply; record that in the manifest so the signal is self-describing.
TOTP_REQUIRED=false
[ "$ENV_TARGET" = "live" ] && TOTP_REQUIRED=true

emit_manifest() {
  cat <<JSON
{
  "schema": "tysonx.cicd.release-signal/v1",
  "contract": "C178289477824693",
  "env": "$ENV_TARGET",
  "domain": "$DOMAIN",
  "ref": "$REF",
  "artifact": "$ARTIFACT",
  "approved_at": "$APPROVED_AT",
  "gate": "github-environment:$ENV_TARGET",
  "totp_required": $TOTP_REQUIRED
}
JSON
}

if [ "${CICD_DRY_RUN:-0}" = "1" ]; then
  log "[dry-run] would write release signal: $MANIFEST_PATH"
  emit_manifest
  exit 0
fi

mkdir -p "$SIGNAL_DIR" || die "cannot create signal dir: $SIGNAL_DIR" 2
emit_manifest > "$MANIFEST_PATH" || die "failed to write manifest: $MANIFEST_PATH" 2
log "release signal emitted: $MANIFEST_PATH (env=$ENV_TARGET domain=$DOMAIN ref=$REF)"
exit 0
