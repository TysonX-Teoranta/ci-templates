#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -n ] && shift
case " $* " in
  *" status "*) printf '%s\n' "${FAKE_LIFECYCLE:-}";;
  *) exit 99;;
esac
EOF
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" release list "*) printf '%s\n' "${FAKE_RC:-}";;
  *" run list "*) printf '%s\n' "${FAKE_RUN:-}";;
  *" run view "*) printf 'Latest run: completed success https://example.invalid/run\n';;
  *) exit 98;;
esac
EOF
chmod +x "$tmp/bin/sudo" "$tmp/bin/gh"

PATH="$tmp/bin:$PATH" "$here/devrc" help | grep -F 'devrc order lodgers' >/dev/null

active='{"id":"lc_active","domain":"lodgers","state":"active","created_at":1,"last_heartbeat":2,"ended_at":null,"recovery_reason":null}'
if FAKE_LIFECYCLE="$active" PATH="$tmp/bin:$PATH" "$here/devrc" order lodgers >"$tmp/out" 2>"$tmp/err"; then
  echo 'active lifecycle order unexpectedly succeeded' >&2; exit 1
fi
grep -F 'Nothing was queued or replaced' "$tmp/err" >/dev/null

complete='{"id":"lc_done","domain":"lodgers","state":"complete","created_at":1,"last_heartbeat":2,"ended_at":3,"recovery_reason":null}'
if FAKE_LIFECYCLE="$complete" FAKE_RC='v1.2.3-rc.4' PATH="$tmp/bin:$PATH" \
  "$here/devrc" order lodgers >"$tmp/out" 2>"$tmp/err"; then
  echo 'occupied candidate order unexpectedly succeeded' >&2; exit 1
fi
grep -F 'already occupies the singleton slot' "$tmp/err" >/dev/null

FAKE_LIFECYCLE="$complete" FAKE_RC='v1.2.3-rc.4' FAKE_RUN=123 \
  PATH="$tmp/bin:$PATH" "$here/devrc" status lodgers >"$tmp/out"
grep -F 'Lifecycle: complete (lc_done)' "$tmp/out" >/dev/null
grep -F 'Open RC:   v1.2.3-rc.4' "$tmp/out" >/dev/null

echo 'devrc selftest: passed'
