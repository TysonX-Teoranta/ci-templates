#!/usr/bin/env bash
# deploy-pull.sh — CICD v2 pull-agent deploy runner (contract C178289477824693, Phase 5).
#
# A deterministic, zero-AI pull agent. It runs on a deploy host (invoked by the
# deploy-pull.timer, one pass per tick — NOT a long-lived daemon) and, per domain:
#   1. polls a release channel for the latest signed release manifest,
#   2. VERIFIES the cosign signature against the Phase-3 public key BEFORE applying,
#   3. verifies the artifact digest against the (now-trusted) manifest,
#   4. vault-injects secrets at deploy time via the existing accessor (secctl/credvault),
#   5. atomically repoints `current` at the new release,
#   6. retains only the last N (default 3) artifacts per domain for rollback.
#
# Fail-closed: an unsigned, wrong-key, tampered, or digest-mismatched release is
# never applied. Zero AI at runtime — the whole path is deterministic bash.
# Fleet V3: strict mode, -v verbose, --dry-run, offline-testable via
# cicd/deploy-pull-selftest.sh.
#
# This ships as a reviewable file. It is NOT installed, enabled, or started here;
# the accompanying systemd unit files under cicd/deploy/systemd/ are files only.

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

show_help() {
  cat <<'EOF'
deploy-pull.sh — CICD v2 pull-agent deploy runner.

Usage:
  deploy-pull.sh --once [--domain <name>]
                 [--channel <dir|url>] [--deploy-base <dir>] [--pubkey <file>]
                 [--retain <n>] [-v] [--dry-run]
  deploy-pull.sh --list          list active deploy domains and exit

One --once pass polls every active domain (or just --domain <name>), verifies the
signed manifest against the Phase-3 cosign public key, and applies it if newer.
Designed to be triggered by deploy-pull.timer; idempotent — re-running with no new
release is a clean no-op.

Config (flags override these env vars; env overrides the built-in defaults):
  RELEASE_CHANNEL   dir path or http(s):// base to pull manifests+artifacts from
  DEPLOY_BASE       per-domain state root            (default /var/lib/tysonx-deploy)
  COSIGN_PUBKEY     Phase-3 cosign public key        (default $DEPLOY_BASE/keys/cosign-phase3.pub)
  COSIGN_BIN        cosign binary                    (default cosign)
  SECCTL_BIN        vault accessor (secctl/credvault)(default secctl)
  RETAIN            artifacts kept per domain         (default 3)

Channel layout (per domain <d>):
  <channel>/<d>/release.json        flat JSON: domain, version, artifact, sha256
  <channel>/<d>/release.json.sig    cosign sign-blob signature over release.json
  <channel>/<d>/<artifact>          the release tarball named by manifest.artifact

Exit: 0 success/no-op/list/dry-run · 1 a domain failed to deploy · 2 usage · 3 missing tool
EOF
}
usage() { [ "${1:-2}" = "0" ] && { show_help; exit 0; }
          err "see --help for usage"; exit "${1:-2}"; }

# --- Defaults (env-overridable; flags win over env) --------------------------
DEPLOY_BASE="${DEPLOY_BASE:-/var/lib/tysonx-deploy}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-}"
COSIGN_PUBKEY="${COSIGN_PUBKEY:-}"
COSIGN_BIN="${COSIGN_BIN:-cosign}"
SECCTL_BIN="${SECCTL_BIN:-secctl}"
RETAIN="${RETAIN:-3}"
ONLY_DOMAIN=""
DO_ONCE=0
LIST_ONLY=0

# --- Arg parse ---------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --once)        DO_ONCE=1; shift ;;
    --domain)      ONLY_DOMAIN="${2:-}"; shift 2 ;;
    --channel)     RELEASE_CHANNEL="${2:-}"; shift 2 ;;
    --deploy-base) DEPLOY_BASE="${2:-}"; shift 2 ;;
    --pubkey)      COSIGN_PUBKEY="${2:-}"; shift 2 ;;
    --retain)      RETAIN="${2:-}"; shift 2 ;;
    --list)        LIST_ONLY=1; shift ;;
    -v|--verbose)  CICD_VERBOSE=1; shift ;;
    --dry-run)     CICD_DRY_RUN=1; shift ;;
    -h|--help)     usage 0 ;;
    *)             err "unknown argument: $1"; usage 2 ;;
  esac
done
export CICD_VERBOSE CICD_DRY_RUN

# Default the Phase-3 key path off the (possibly flag-supplied) DEPLOY_BASE.
[ -n "$COSIGN_PUBKEY" ] || COSIGN_PUBKEY="$DEPLOY_BASE/keys/cosign-phase3.pub"

case "$RETAIN" in
  ''|*[!0-9]*) err "invalid --retain (want a positive integer): $RETAIN"; usage 2 ;;
esac
[ "$RETAIN" -ge 1 ] || { err "--retain must be >= 1"; usage 2 ; }

# --- Active-domain selection (from domains.yml via common.sh) -----------------
# active_domains — echo every domain whose registry status is exactly "active".
active_domains() {
  local d
  while IFS= read -r d; do
    [ "$(domain_field "$d" status)" = "active" ] && printf '%s\n' "$d"
  done < <(domains_list)
}

if [ "$LIST_ONLY" = "1" ]; then
  active_domains
  exit 0
fi

# --- Manifest parsing --------------------------------------------------------
# manifest_get <file> <key> — read one flat string field from the JSON manifest.
# Manifests are flat (no nesting) by contract, so a scoped sed is sufficient and
# avoids a jq dependency on the deploy host.
manifest_get() {
  local file="$1" key="$2"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n1
}

# --- Channel fetch (read-only; never guarded by dry-run) ----------------------
# fetch_channel <relpath> <dest> — copy one channel object into <dest>. Returns
# non-zero (without dying) if the object is absent, so a poll with nothing new is
# a clean no-op rather than a failure.
fetch_channel() {
  local rel="$1" dest="$2" src
  case "$RELEASE_CHANNEL" in
    http://*|https://*)
      require curl
      curl -fsSL "$RELEASE_CHANNEL/$rel" -o "$dest" 2>/dev/null || return 1
      ;;
    *)
      src="$RELEASE_CHANNEL/$rel"
      [ -f "$src" ] || return 1
      cp "$src" "$dest" || return 1
      ;;
  esac
  return 0
}

# --- Signature verification (fail-closed; the security boundary) --------------
# verify_signature <manifest> <sig> — cosign verify-blob against the Phase-3 key.
# Returns non-zero on ANY doubt (missing key/sig, bad signature, missing cosign).
verify_signature() {
  local manifest="$1" sig="$2"
  [ -f "$COSIGN_PUBKEY" ] || { err "Phase-3 public key not found: $COSIGN_PUBKEY"; return 1; }
  [ -f "$sig" ]           || { err "release signature missing: $sig"; return 1; }
  have "$COSIGN_BIN"      || { err "cosign not found on PATH: $COSIGN_BIN"; return 1; }
  vlog "cosign verify-blob --key $COSIGN_PUBKEY --signature $sig $manifest"
  "$COSIGN_BIN" verify-blob --key "$COSIGN_PUBKEY" --signature "$sig" "$manifest" \
    >/dev/null 2>&1 || { err "cosign signature verification FAILED for $manifest"; return 1; }
  return 0
}

# --- Digest verification -----------------------------------------------------
# verify_digest <artifact> <expected-sha256> — confirm the tarball matches the
# (now signature-trusted) manifest digest before it is ever unpacked.
verify_digest() {
  local artifact="$1" want="$2" got
  require sha256sum
  got="$(sha256sum "$artifact" | awk '{print $1}')"
  [ "$got" = "$want" ] || { err "digest mismatch for $artifact: got $got want $want"; return 1; }
  return 0
}

# --- Secret injection (deploy time, via the vault accessor) -------------------
# inject_secrets <domain> <envfile> — render the domain's secrets into <envfile>
# (mode 600) using the existing accessor. Secrets are injected fresh at deploy
# time, never baked into the artifact. The accessor contract: `<bin> render-env
# --domain <d>` writes KEY=VALUE lines to stdout.
inject_secrets() {
  local domain="$1" envfile="$2"
  if [ "${CICD_DRY_RUN:-0}" = "1" ]; then
    log "[DRYRUN] would inject secrets for $domain via $SECCTL_BIN -> $envfile (mode 600)"
    return 0
  fi
  have "$SECCTL_BIN" || { err "vault accessor not found on PATH: $SECCTL_BIN"; return 1; }
  ( umask 077; "$SECCTL_BIN" render-env --domain "$domain" > "$envfile" ) \
    || { err "secret injection failed for $domain (accessor: $SECCTL_BIN)"; return 1; }
  chmod 600 "$envfile" 2>/dev/null || true
  return 0
}

# --- Deployed-version bookkeeping --------------------------------------------
# current_version <domain> — the version currently pointed at (empty if none).
current_version() {
  local domain="$1"
  local f="$DEPLOY_BASE/$domain/current-version"
  [ -f "$f" ] && cat "$f" || printf ''
}

# --- Retention: keep only the last N releases per domain ----------------------
# History is an explicit oldest->newest ledger so pruning is deterministic and
# never depends on filesystem mtime resolution.
#
# prune_releases <domain> — trim releases/ down to the newest $RETAIN, deleting
# both the on-disk release dir and its history line for anything older.
prune_releases() {
  local domain="$1"
  local hist="$DEPLOY_BASE/$domain/releases/.history"
  local rel_root="$DEPLOY_BASE/$domain/releases" count old tmp
  [ -f "$hist" ] || return 0
  count="$(wc -l < "$hist" | tr -d ' ')"
  while [ "$count" -gt "$RETAIN" ]; do
    old="$(head -n1 "$hist")"
    if [ -n "$old" ] && [ -d "$rel_root/$old" ]; then
      vlog "prune: removing old release $domain/$old"
      rm -rf "${rel_root:?}/${old:?}"
    fi
    tmp="$(mktemp)"
    tail -n +2 "$hist" > "$tmp" && mv "$tmp" "$hist"
    count="$((count - 1))"
  done
  return 0
}

# --- Apply one release (the only host-mutating step) --------------------------
# apply_release <domain> <version> <artifact> — unpack into releases/<version>,
# inject secrets, atomically repoint current, record + prune. Dry-run logs the
# intended mutations without touching the deploy base.
apply_release() {
  local domain="$1" version="$2" artifact="$3"
  local droot="$DEPLOY_BASE/$domain"
  local rel_root="$droot/releases" reldir="$droot/releases/$version"

  if [ "${CICD_DRY_RUN:-0}" = "1" ]; then
    log "[DRYRUN] would unpack $artifact -> $reldir"
    inject_secrets "$domain" "$reldir/secrets.env"   # self-logs [DRYRUN]
    log "[DRYRUN] would repoint $droot/current -> releases/$version and prune to $RETAIN"
    return 0
  fi

  mkdir -p "$reldir" "$rel_root"
  tar -xzf "$artifact" -C "$reldir" || { err "unpack failed for $domain/$version"; return 1; }

  inject_secrets "$domain" "$reldir/secrets.env" || return 1

  # Atomic swap: build the symlink beside the target, then rename over `current`.
  ln -sfn "releases/$version" "$droot/.current.next" || { err "symlink stage failed"; return 1; }
  mv -Tf "$droot/.current.next" "$droot/current"     || { err "symlink swap failed"; return 1; }
  printf '%s\n' "$version" > "$droot/current-version"

  # Record in the retention ledger (append only if not already present) + prune.
  local hist="$rel_root/.history"
  touch "$hist"
  grep -qxF "$version" "$hist" || printf '%s\n' "$version" >> "$hist"
  prune_releases "$domain"
  return 0
}

# --- Per-domain orchestration ------------------------------------------------
# deploy_domain <domain> — the full pull->verify->apply pipeline for one domain.
# Returns 0 on deploy OR clean no-op; 1 on a real failure.
deploy_domain() {
  local domain="$1"
  local stage manifest sig version artifact sha256 art_path
  stage="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" RETURN

  manifest="$stage/release.json"
  sig="$stage/release.json.sig"

  if ! fetch_channel "$domain/release.json" "$manifest"; then
    log "$domain: no release manifest on channel — nothing to do"
    return 0
  fi
  fetch_channel "$domain/release.json.sig" "$sig" || true   # absence handled by verify

  version="$(manifest_get "$manifest" version)"
  artifact="$(manifest_get "$manifest" artifact)"
  sha256="$(manifest_get "$manifest" sha256)"

  # Validate the manifest fields BEFORE trusting them for any filesystem path.
  case "$version" in
    ''|*[!A-Za-z0-9._-]*) err "$domain: missing/invalid manifest version: '$version'"; return 1 ;;
  esac
  case "$artifact" in
    ''|*/*|..*) err "$domain: missing/invalid manifest artifact: '$artifact'"; return 1 ;;
  esac
  case "$sha256" in
    ''|*[!a-f0-9]*) err "$domain: missing/invalid manifest sha256"; return 1 ;;
  esac

  # Idempotent poll: nothing to do if this version is already current.
  if [ "$version" = "$(current_version "$domain")" ]; then
    log "$domain: already at $version — no-op"
    return 0
  fi

  # SECURITY BOUNDARY: verify the signature against the Phase-3 key BEFORE we
  # fetch, unpack, or apply anything derived from the manifest.
  verify_signature "$manifest" "$sig" || { err "$domain: refusing unsigned/invalid release $version"; return 1; }
  log "$domain: signature OK for $version (Phase-3 key)"

  art_path="$stage/$artifact"
  fetch_channel "$domain/$artifact" "$art_path" || { err "$domain: artifact fetch failed: $artifact"; return 1; }
  verify_digest "$art_path" "$sha256" || { err "$domain: refusing digest-mismatched release $version"; return 1; }
  log "$domain: digest OK for $version"

  apply_release "$domain" "$version" "$art_path" || { err "$domain: apply failed for $version"; return 1; }
  log "$domain: deployed $version (retain last $RETAIN)"
  return 0
}

# --- Poll pass ---------------------------------------------------------------
deploy_once() {
  [ -n "$RELEASE_CHANNEL" ] || die "no release channel set (--channel or RELEASE_CHANNEL)" 2
  local domain rc=0 targets
  if [ -n "$ONLY_DOMAIN" ]; then
    domain_exists "$ONLY_DOMAIN" || die "unknown domain: $ONLY_DOMAIN" 2
    [ "$(domain_field "$ONLY_DOMAIN" status)" = "active" ] || die "domain not active: $ONLY_DOMAIN" 2
    targets="$ONLY_DOMAIN"
  else
    targets="$(active_domains)"
  fi
  [ -n "$targets" ] || { log "no active deploy domains — nothing to do"; return 0; }
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    deploy_domain "$domain" || rc=1
  done <<< "$targets"
  return "$rc"
}

# --- Entry -------------------------------------------------------------------
[ "$DO_ONCE" = "1" ] || { err "nothing to do: pass --once (see --help)"; usage 2; }
deploy_once
exit $?
