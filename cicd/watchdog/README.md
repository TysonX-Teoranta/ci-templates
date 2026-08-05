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

The committed acceptance battery includes hard/no-progress timeouts, a real `dotnet test` testhost hang,
Coverlet collector execution followed by a post-test wedge, descendant cleanup, a bounded wedged dump collector,
partial coverage rejection, near-deadline valid work, quiet heartbeat-driven work, a missing-cancellation
simulation, and a real clean .NET/Coverlet follow-up after every fault. It also proves that exactly one retry is
made for an infrastructure classification and that an assertion exit is never retried.

The real fixture pins the Lodgers versions: Microsoft.NET.Test.Sdk 18.6.0, coverlet.collector 10.0.1, NUnit
4.6.1, and NUnit3TestAdapter 6.2.0. Cleanup hashes the built fixture before and after every fault and removes its
collector results. Diagnostics and all Cobertura evidence are retained for 30 days.

The disposable image must match the primary runner's OS, architecture, SDK, Coverlet/testhost, cgroup/systemd,
CPU, and memory limits. Destroy it after retaining diagnostics. Promotion to a primary runner is limited to
non-destructive canaries and remains disabled until the full repeated battery passes.
