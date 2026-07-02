#!/usr/bin/env bash
# deploy-pull-selftest.sh — offline harness for deploy-pull.sh (contract C178289477824693, Phase 5).
#
# Proves the pull-agent's security + retention logic WITHOUT a real cosign key, a
# real vault, a network, or a live host. It stands up a temp release channel, a
# temp deploy base, a fake cosign (verify-blob succeeds iff the signature equals
# sha256(manifest) — so tampering breaks it exactly as real cosign would) and a
# fake vault accessor, then drives real deploy passes and asserts on the outcome.
#
# Run: cicd/deploy-pull-selftest.sh [-v]
# Deterministic, zero-AI, no network. Exit 0 = all green, 1 = a failure.

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

[ "${1:-}" = "-v" ] && CICD_VERBOSE=1
export CICD_VERBOSE

SCRIPT="$CICD_ROOT/deploy-pull.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok() {  # ok <label> <actual> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); vlog "PASS $1 ($2)"
  else FAIL=$((FAIL + 1)); err "FAIL $1: got '$2' expected '$3'"; fi
}
ok_rc() {  # ok_rc <label> <actual-rc> <expected-rc>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); vlog "PASS $1 (rc=$2)"
  else FAIL=$((FAIL + 1)); err "FAIL $1: rc $2 expected $3"; fi
}

# --- Fakes on PATH: cosign (signature) + secctl (vault accessor) --------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/cosign" <<'FAKE'
#!/usr/bin/env bash
# Fake cosign: `verify-blob --key K --signature SIG BLOB` succeeds iff SIG's
# contents equal sha256(BLOB) — models a signature that breaks on any tampering.
[ "$1" = "verify-blob" ] || exit 2
shift
sig=""; blob=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key)       shift 2 ;;
    --signature) sig="$2"; shift 2 ;;
    *)           blob="$1"; shift ;;
  esac
done
[ -f "$sig" ] && [ -f "$blob" ] || exit 1
[ "$(sha256sum "$blob" | awk '{print $1}')" = "$(cat "$sig")" ]
FAKE
cat > "$BIN/secctl" <<'FAKE'
#!/usr/bin/env bash
# Fake vault accessor: `render-env --domain D` emits that domain's secret lines.
[ "$1" = "render-env" ] || exit 2
printf 'DOMAIN_SECRET=s3cr3t-for-%s\n' "$3"
FAKE
chmod +x "$BIN/cosign" "$BIN/secctl"
export PATH="$BIN:$PATH"

PUBKEY="$WORK/cosign-phase3.pub"; printf 'FAKE-PHASE3-PUBKEY\n' > "$PUBKEY"

# --- Controlled registry: one active domain + one on-hold domain --------------
REG="$WORK/domains.yml"
cat > "$REG" <<'EOF'
version: 1
domains:
  acme:
    repo: TysonX-Teoranta/acme
    status: active
  dormant:
    repo: TysonX-Teoranta/dormant
    status: on-hold
EOF
export CICD_REGISTRY="$REG"

CHAN="$WORK/channel"
BASE="$WORK/deploy"

# make_release <domain> <version> <content> — publish a validly SIGNED release.
make_release() {
  local domain="$1" version="$2" content="$3"
  local dir="$CHAN/$domain" art="acme-$version.tar.gz" payload="$WORK/payload"
  mkdir -p "$dir" "$payload"
  printf '%s\n' "$content" > "$payload/app.txt"
  tar -czf "$dir/$art" -C "$payload" app.txt
  local sha; sha="$(sha256sum "$dir/$art" | awk '{print $1}')"
  cat > "$dir/release.json" <<EOF
{ "domain": "$domain", "version": "$version", "artifact": "$art", "sha256": "$sha" }
EOF
  # "Sign": in the fake-cosign model the signature is sha256 of the manifest.
  sha256sum "$dir/release.json" | awk '{print $1}' > "$dir/release.json.sig"
}

run_pull() {  # run_pull <extra-args...> — one --once pass over the temp channel.
  bash "$SCRIPT" --once --channel "$CHAN" --deploy-base "$BASE" \
       --pubkey "$PUBKEY" --retain 3 "$@"
}

# === Test 1: --list shows only the active domain ==============================
ok "list/active-only" "$(bash "$SCRIPT" --list | tr '\n' ',')" "acme,"

# === Test 2: a valid signed release deploys ==================================
make_release acme v1 "release-one"
run_pull >/dev/null 2>&1; ok_rc "deploy/v1-rc" "$?" "0"
ok "deploy/current-version" "$(cat "$BASE/acme/current-version" 2>/dev/null)" "v1"
ok "deploy/current-symlink" "$(readlink "$BASE/acme/current" 2>/dev/null)" "releases/v1"
ok "deploy/payload-present" "$(cat "$BASE/acme/current/app.txt" 2>/dev/null)" "release-one"
ok "deploy/secrets-injected" "$(cat "$BASE/acme/current/secrets.env" 2>/dev/null)" "DOMAIN_SECRET=s3cr3t-for-acme"
ok "deploy/secrets-mode" "$(stat -c '%a' "$BASE/acme/current/secrets.env" 2>/dev/null)" "600"

# === Test 3: re-poll with no new release is an idempotent no-op ===============
run_pull >/dev/null 2>&1; ok_rc "idempotent/rc" "$?" "0"
ok "idempotent/still-v1" "$(cat "$BASE/acme/current-version")" "v1"

# === Test 4: tampered manifest (signature no longer matches) is REJECTED ======
make_release acme v2 "release-two"
# Tamper AFTER signing: flip the version so sha256(manifest) != signature.
sed -i 's/"version": "v2"/"version": "v2x"/' "$CHAN/acme/release.json"
run_pull >/dev/null 2>&1; ok_rc "tamper/rejected-rc" "$?" "1"
ok "tamper/not-applied" "$(cat "$BASE/acme/current-version")" "v1"

# === Test 5: unsigned release (no .sig) is REJECTED ==========================
make_release acme v3 "release-three"
rm -f "$CHAN/acme/release.json.sig"
run_pull >/dev/null 2>&1; ok_rc "unsigned/rejected-rc" "$?" "1"
ok "unsigned/not-applied" "$(cat "$BASE/acme/current-version")" "v1"

# === Test 6: digest mismatch (signed manifest, wrong artifact) is REJECTED ====
make_release acme v4 "release-four"
# Repack the artifact with different bytes WITHOUT re-signing: manifest sha256
# is stale, so the signature still verifies but the digest check must catch it.
printf 'swapped\n' > "$WORK/swap.txt"
tar -czf "$CHAN/acme/acme-v4.tar.gz" -C "$WORK" swap.txt
run_pull >/dev/null 2>&1; ok_rc "digest/rejected-rc" "$?" "1"
ok "digest/not-applied" "$(cat "$BASE/acme/current-version")" "v1"

# === Test 7: retention keeps only the last 3 artifacts =======================
# Deploy v10..v14 cleanly; after 5 deploys only the newest 3 dirs survive.
for n in 10 11 12 13 14; do
  make_release acme "v$n" "rel-$n"
  run_pull >/dev/null 2>&1
done
ok "retain/current-newest" "$(cat "$BASE/acme/current-version")" "v14"
ok "retain/count-is-3" "$(find "$BASE/acme/releases" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" "3"
ok "retain/oldest-pruned" "$( [ -d "$BASE/acme/releases/v10" ] && echo present || echo gone )" "gone"
ok "retain/second-oldest-pruned" "$( [ -d "$BASE/acme/releases/v11" ] && echo present || echo gone )" "gone"
ok "retain/kept-v12" "$( [ -d "$BASE/acme/releases/v12" ] && echo present || echo gone )" "present"
ok "retain/kept-v13" "$( [ -d "$BASE/acme/releases/v13" ] && echo present || echo gone )" "present"
ok "retain/kept-v14" "$( [ -d "$BASE/acme/releases/v14" ] && echo present || echo gone )" "present"
ok "retain/history-3-lines" "$(wc -l < "$BASE/acme/releases/.history" | tr -d ' ')" "3"

# === Test 8: dry-run mutates NOTHING =========================================
DRYBASE="$WORK/dry"
make_release acme v20 "dry-release"
bash "$SCRIPT" --once --channel "$CHAN" --deploy-base "$DRYBASE" \
     --pubkey "$PUBKEY" --dry-run >/dev/null 2>&1
ok_rc "dryrun/rc" "$?" "0"
ok "dryrun/no-current" "$( [ -e "$DRYBASE/acme/current" ] && echo made || echo none )" "none"
ok "dryrun/no-releases" "$( [ -d "$DRYBASE/acme/releases" ] && echo made || echo none )" "none"

# === Test 9: usage guards ====================================================
bash "$SCRIPT" >/dev/null 2>&1; ok_rc "usage/no-once" "$?" "2"
bash "$SCRIPT" --once --deploy-base "$BASE" --pubkey "$PUBKEY" >/dev/null 2>&1
ok_rc "usage/no-channel" "$?" "2"
run_pull --domain nope >/dev/null 2>&1; ok_rc "usage/unknown-domain" "$?" "2"

# --- Verdict -----------------------------------------------------------------
log "deploy-pull selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
