#!/usr/bin/env bash
# OPERATOR-ONLY Pulse installer for the command-level sudo policy. No root shell is used.
set -euo pipefail

[ "$(id -un)" = tysonxpulse ] || { echo "run as tysonxpulse on Pulse" >&2; exit 1; }
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "operator installation requires an interactive terminal" >&2
  exit 77
fi
source_dir=$(cd "$(dirname "$0")" && pwd)

for file in rc-authorization.py rc-authorization-entrypoint.sh rc-supervisor.sh \
  rc-authorization-sudoers; do
  [ -s "$source_dir/$file" ] || { echo "payload file is missing: $file" >&2; exit 1; }
done

# Validate the candidate before the privileged copy. Pulse deliberately denies sudo visudo.
/usr/sbin/visudo -cf "$source_dir/rc-authorization-sudoers"
sudo /usr/bin/test -s /etc/tysonx/gate-seed
sudo /usr/bin/id tysonxpulse >/dev/null

sudo /usr/bin/install -d -o root -g root -m 0755 \
  /usr/local/libexec/tier0 /usr/local/sbin
sudo /usr/bin/install -d -o root -g root -m 0700 /etc/tier0 /var/lib/tier0
sudo /usr/bin/install -o root -g root -m 0755 "$source_dir/rc-authorization.py" \
  /usr/local/libexec/tier0/rc-authorization.py
sudo /usr/bin/install -o root -g root -m 0755 "$source_dir/rc-authorization-entrypoint.sh" \
  /usr/local/sbin/tier0-rc-authorization
sudo /usr/bin/install -o root -g root -m 0755 "$source_dir/rc-supervisor.sh" \
  /usr/local/libexec/tier0/rc-supervisor.sh

if ! sudo /usr/bin/test -s /etc/tier0/auth-signing-key; then
  sudo /usr/bin/openssl rand -base64 -out /etc/tier0/auth-signing-key 48
fi
sudo /usr/bin/chown root:root /etc/tier0/auth-signing-key
sudo /usr/bin/chmod 0600 /etc/tier0/auth-signing-key
sudo /usr/bin/install -o root -g root -m 0440 "$source_dir/rc-authorization-sudoers" \
  /etc/sudoers.d/90-tier0-rc-authorization

# Execute the installed shebang script directly; sudo policy continues to deny Python itself.
sudo /usr/local/libexec/tier0/rc-authorization.py --store \
  /var/lib/tier0/rc-authorizations.sqlite3 init
echo "Tier 0 RC authorization boundary installed; enforcement is not enabled by this payload."
