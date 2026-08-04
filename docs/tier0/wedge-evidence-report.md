# Wedge evidence report

Capture date: 2026-08-04

Source: primary runner diagnostics on `tysonx-dev`

Status: partial historical capture; no active wedge at capture time

## Preserved evidence

- Runner diagnostics are retained under `/home/deploy/actions-runner-org/_diag` and include Runner and Worker
  logs spanning the known coverage incidents.
- Worker diagnostics document that dynamic/profiler coverage on linux-arm64 produced empty Cobertura output,
  static `dotnet-coverage` lacked branch data, and unscoped offline Coverlet instrumentation timed out.
- Worker diagnostics identify run `30779316883` as a successful no-heap-cap reference: 3,303 tests, zero
  failures, approximately 44 minutes.
- Worker diagnostics identify run `30795072683` and two following attempts as process-level OOM failures after
  a 45% GC heap ceiling was introduced. The recorded testhost peak was 7.6 GiB plus approximately 1.2 GiB for
  Coverlet; host RAM was not exhausted.
- Runner diagnostics show GitHub cancellation messages reaching the runner in historical cases, jobs completing
  as `Canceled`, and the runner itself later shutting down for `UserCancelled`. This proves some cancellations
  arrived; it does not prove arrival for every known wedge.
- At capture time, the complete process inventory contained no surviving `dotnet-coverage`, `testhost`, `vstest`,
  or dump-collector process. Only the runner service processes were present.

## Evidence gaps

| Required evidence | State |
|---|---|
| Exact Actions logs and metadata for every known wedge | Unavailable: the dev PAT receives HTTP 403 for Actions-run reads |
| Incident-time process tree/cgroup | Not preserved in the located evidence |
| Incident-specific Coverlet/testhost/dump-collector PIDs | Not preserved in the located evidence |
| Proof cancellation reached each wedged job | Unknown; only other historical cancellations are confirmed |
| Manual cleanup command/timeline for each wedge | Not present in the located runner diagnostics |
| Before/after hashes of rewritten assemblies and temporary files | Not preserved |
| Clean follow-up suite immediately after each historical fault | Not bound to the fault records located so far |

## Conclusion

The current evidence establishes real ARM64 coverage failure modes and incomplete historical cleanup evidence.
It does not satisfy watchdog promotion. The isolated acceptance harness must therefore capture the scope tree,
dump outcome, cleanup result, temporary/instrumented-file state, and a clean follow-up suite after every injected
fault. No historical gap may be converted into a pass by assumption.
