# Ordering and managing the Lodgers devRC singleton

Run the operator command on Pulse:

```bash
ssh -t tysonx-pulse
devrc status lodgers
devrc order lodgers
devrc wait lodgers
```

`devrc order lodgers` is the supported RC creation mechanism. It checks both
singleton boundaries before prompting for the human operator's TOTP:

1. A `building` or `active` lifecycle refuses the order. Nothing is queued,
   replaced or cancelled.
2. A completed open RC prerelease also refuses the order because it occupies
   the one-candidate slot.
3. With both slots clear, the command prompts for TOTP on the Pulse terminal,
   creates a short-lived one-use authorization and dispatches
   `finalise-rc.yml` from `lodgers-dev`.

Management commands:

- `devrc status lodgers`: lifecycle, open candidate and latest workflow.
- `devrc history lodgers [N]`: recent RC orders and results.
- `devrc wait lodgers`: watch the latest order and require lifecycle `complete`.
- `devrc drop lodgers`: remove a completed open RC. It refuses during an active
  lifecycle and requires the operator to type the exact tag. Dropping burns the
  RC number; it is never reused.

The SQLite authorization store remains root-owned. The command only reaches it
through the installed authorization boundary and never reads or writes it
directly.
