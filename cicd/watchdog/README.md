# Tier 0 watchdog

`test-watchdog.sh` owns the full test tree in a systemd user scope, observes an explicit heartbeat, separates
test and coverage deadlines, bounds dump collection, kills the complete cgroup, and reports infrastructure
timeouts separately from ordinary test exits.

Destructive acceptance is deliberately not runnable on a normal runner. `isolated-acceptance.sh` requires all
of the following:

- `TIER0_DISPOSABLE_RUNNER=1`;
- the exact `tier0-disposable` runner label;
- an assertion that deployment credentials are absent;
- `PRIMARY_RUNNER=0`, proving the runner inventory classified it as disposable.

The committed acceptance battery includes hard/no-progress timeouts, a coverage wedge, descendant cleanup,
partial coverage rejection, near-deadline valid work, quiet heartbeat-driven work, and a clean follow-up after
every scenario. The disposable image must additionally supply real testhost, Coverlet, dump-collector, and
GitHub-cancellation fixtures before promotion; the shell fixtures do not substitute for those integration cases.

The disposable image must match the primary runner's OS, architecture, SDK, Coverlet/testhost, cgroup/systemd,
CPU, and memory limits. Destroy it after retaining diagnostics. Promotion to a primary runner is limited to
non-destructive canaries and remains disabled until the full repeated battery passes.
