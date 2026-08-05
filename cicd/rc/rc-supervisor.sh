#!/usr/bin/env bash
# Root-owned Pulse service that supervises a devRC independently of Actions runners.
set -euo pipefail

mode=${1:-}; shift || true
LIFECYCLE_ID=${1:-}; ACTOR=${2:-}; REPOSITORY=${3:-}; RUN_ID=${4:-}
[[ "$LIFECYCLE_ID" =~ ^[A-Za-z0-9_-]{10,64}$ ]] || exit 64
[[ "$ACTOR" =~ ^[A-Za-z0-9_-]+$ ]] || exit 64
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 64
[[ "$RUN_ID" =~ ^[0-9]+$ ]] || exit 64
unit="tier0-rc-supervisor-$LIFECYCLE_ID"

if [ "$mode" = start ]; then
  exec systemd-run --unit="$unit" --collect --quiet --property=KillMode=control-group -- \
    /usr/local/libexec/tier0/rc-supervisor.sh run "$LIFECYCLE_ID" "$ACTOR" "$REPOSITORY" "$RUN_ID"
fi
[ "$mode" = run ] || exit 64

export HOME=/home/deploy GH_CONFIG_DIR=/home/deploy/.config/gh
auth=(/usr/local/libexec/tier0/rc-authorization.py --store /var/lib/tier0/rc-authorizations.sqlite3)
started=$(date +%s); api_failures=0
while :; do
  if jobs=$(gh api "repos/$REPOSITORY/actions/runs/$RUN_ID/jobs?per_page=100" 2>/dev/null); then
    api_failures=0
    read -r status conclusion < <(jq -r '[.jobs[] | select(.name | contains("Finalise RC"))] | last |
      if . == null then "pending pending" else "\(.status) \(.conclusion // "pending")" end' <<< "$jobs")
    if [ "$status" = completed ]; then
      if [ "$conclusion" = success ]; then
        "${auth[@]}" lifecycle activate --lifecycle-id "$LIFECYCLE_ID" --actor "$ACTOR"
        "${auth[@]}" lifecycle complete --lifecycle-id "$LIFECYCLE_ID" --actor "$ACTOR"
      else
        "${auth[@]}" lifecycle fail --lifecycle-id "$LIFECYCLE_ID" --actor "$ACTOR"
      fi
      exit 0
    fi
  else
    api_failures=$((api_failures + 1))
  fi
  now=$(date +%s)
  if [ "$api_failures" -ge 5 ] || [ $((now - started)) -ge 21540 ]; then
    "${auth[@]}" lifecycle fail --lifecycle-id "$LIFECYCLE_ID" --actor "$ACTOR"
    gh api --method POST "repos/$REPOSITORY/actions/runs/$RUN_ID/cancel" || true
    exit 124
  fi
  "${auth[@]}" lifecycle heartbeat --lifecycle-id "$LIFECYCLE_ID" --actor "$ACTOR"
  sleep 60
done
