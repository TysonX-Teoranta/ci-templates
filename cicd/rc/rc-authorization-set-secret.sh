#!/usr/bin/env bash
# OPERATOR-ONLY installation of the dedicated Tier 0 TOTP seed without shell history exposure.
set -euo pipefail

[ "$(id -un)" = tysonxpulse ] || { echo "run as tysonxpulse on Pulse" >&2; exit 1; }
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "secret installation requires an interactive terminal" >&2
  exit 77
fi

secret=""
temporary=""
cleanup() {
  secret=""
  if [ -n "$temporary" ] && [ -f "$temporary" ]; then
    /usr/bin/shred -u "$temporary"
  fi
}
trap cleanup EXIT HUP INT TERM

IFS= read -r -s -p "Tier 0 TOTP Base32 seed: " secret
echo
secret=$(printf '%s' "$secret" | tr -d '[:space:]-' | tr '[:lower:]' '[:upper:]')
while [[ "$secret" == *= ]]; do
  secret=${secret%=}
done
case "$secret" in
  ''|*[!A-Z2-7]*) echo "seed contains a character outside the Base32 alphabet" >&2; exit 64 ;;
esac
[ "${#secret}" -ge 16 ] || { echo "seed is too short" >&2; exit 64; }

temporary=$(mktemp /home/deploy/.tier0-totp-secret.XXXXXX)
chmod 0600 "$temporary"
printf '%s\n' "$secret" > "$temporary"
secret=""
sudo /usr/bin/install -d -o root -g root -m 0700 /etc/tier0
sudo /usr/bin/install -o root -g root -m 0600 "$temporary" /etc/tier0/totp-secret
echo "Dedicated Tier 0 TOTP secret installed."
