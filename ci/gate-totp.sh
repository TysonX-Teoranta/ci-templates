#!/usr/bin/env bash
# ci/gate-totp.sh <domain> <env> <action> — thin front door to the CROM-PRIVATE TOTP gate.
#
# This is the spine's single entry for the Crom-held human gates:
#   G6 = action 'promote'  (staging -> live promotion)
#   G8 = action 'deploy'   (live deploy)
# It delegates to the proven, replay-proof pulse gate harness — gate-wait.sh -> gate-approve.sh
# (SMS+email alert, per-gate nonce) + gate-poller (validates Crom's email-reply TOTP against
# CROM-PRIVATE seeds). Seeds live ONLY with Crom; no AI can compute the code. Exit 0 ONLY on
# Crom's approval.
#
# The shared gate scripts are reused AS-IS (SPEC §9) and are NOT vendored into the repo — they
# stay on the pulse host where the seeds + poller live, so no inbound path is opened to them.
#
# DRY_RUN=1: HALT at the wall. Print exactly what WOULD fire and exit non-zero WITHOUT enqueuing
# (so a local dev->live proof never pages Crom). This is the "stops at the TOTP wall" behaviour.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DOMAIN="${1:?domain}"; ENV="${2:?env}"; ACTION="${3:?action: promote|deploy|rollback}"
GATE_BASE="${GATE_BASE:-$HOME/tysonx-core/ops/cicd}"
case "$ACTION" in
  promote) G="G6 (staging -> live promote)";;
  deploy)  G="G8 (live deploy)";;
  rollback) G="G10 (rollback)";;
  *) G="(unknown)";;
esac

if [ "$DRY_RUN" = "1" ]; then
  stage "TOTP WALL — $G"
  err  "HALT: ${ACTION} ${DOMAIN}/${ENV} requires Crom's TOTP — $G."
  note "would invoke: $GATE_BASE/gate-wait.sh $DOMAIN $ENV $ACTION"
  note "gate-wait enqueues via gate-approve.sh (SMS+email, no-code, per-gate nonce); blocks up to 24h"
  note "approval = Crom's email-reply TOTP, validated by gate-poller against CROM-PRIVATE seeds (replay-proof)"
  note "NOT fired in dry-run — Crom holds the code. This is the dev->live wall."
  exit 77   # sentinel: reached-the-wall (dry-run halt), not a failure
fi

stage "TOTP gate — $G"
exec "$GATE_BASE/gate-wait.sh" "$DOMAIN" "$ENV" "$ACTION"
