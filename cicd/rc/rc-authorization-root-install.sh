#!/usr/bin/env bash
# OPERATOR-ONLY Pulse installation payload. The Tier 0 TOTP secret is supplied
# separately by the operator; automation must never install or read that secret.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root on Pulse" >&2; exit 1; }
source_dir=$(cd "$(dirname "$0")" && pwd)
[ -s /etc/tier0/totp-secret ] || { echo "operator-supplied Tier 0 TOTP secret is unavailable" >&2; exit 1; }
id tysonxpulse >/dev/null

install -d -o root -g root -m 0755 /usr/local/libexec/tier0 /usr/local/sbin
install -d -o root -g root -m 0700 /etc/tier0 /var/lib/tier0
install -o root -g root -m 0755 "$source_dir/rc-authorization.py" \
  /usr/local/libexec/tier0/rc-authorization.py
install -o root -g root -m 0755 "$source_dir/rc-authorization-entrypoint.sh" \
  /usr/local/sbin/tier0-rc-authorization
install -o root -g root -m 0755 "$source_dir/rc-supervisor.sh" \
  /usr/local/libexec/tier0/rc-supervisor.sh
install -o root -g root -m 0755 "$source_dir/devrc" \
  /usr/local/bin/devrc
if [ ! -s /etc/tier0/auth-signing-key ]; then
  umask 077
  head -c 48 /dev/urandom | base64 > /etc/tier0/auth-signing-key
fi
chown root:root /etc/tier0/auth-signing-key
chmod 0600 /etc/tier0/auth-signing-key
install -o root -g root -m 0440 "$source_dir/rc-authorization-sudoers" \
  /etc/sudoers.d/90-tier0-rc-authorization
visudo -cf /etc/sudoers.d/90-tier0-rc-authorization

# Initialize schema through the same root boundary without issuing an authorization.
/usr/local/libexec/tier0/rc-authorization.py --store \
  /var/lib/tier0/rc-authorizations.sqlite3 init
echo "Tier 0 RC authorization boundary installed; enforcement is not enabled by this payload."
