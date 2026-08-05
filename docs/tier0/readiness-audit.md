# Tier 0 readiness audit

Audit date: 2026-08-04

Scope: Lodgers dev/devRC and the shared CI/CD spine

Execution host: `tysonx-dev`, reached through `tysonx-pulse`

## Repository identity

| Repository | Branch | Commit | Tree | State |
|---|---|---|---|---|
| `TysonX-Teoranta/ci-templates` | `main` | `3852425b9bd42527b9827075eb6ccadb4858f89e` | `e3d2b650b857f0b17a8c1136777823e10938294b` | Clean, matches `origin/main` |
| `TysonX-Teoranta/lodgers` | `lodgers-dev` | `4529670d150e6d54d22ec4d50e9413b4ddcc9e35` | `b08fc4d43eced18753cdc7436c86213049fd033a` | Clean, matches `origin/lodgers-dev` |

`/home/deploy/repo/lodgers-ai` is the existing Lodgers object/reference base and remains the deployment base.
Exact-SHA deployment borrows its Git objects into an isolated `/tmp` clone; it does not create another
`/home/deploy/repo/*` tree and does not reset, clean, or overwrite the existing base. Development validation uses
clean checkouts under `/home/deploy/work`.

## Permissions and infrastructure

| Check | Verified result | Decision |
|---|---|---|
| Host | Ubuntu 24.04, Linux 6.8, ARM64, 8 CPUs, 16,333,643,776 bytes RAM | Primary-runner reference platform |
| .NET | Mutex shim `/home/deploy/bin/dotnet`; SDK 10.0.110; runtime 10.0.10 | All builds/tests must use the shim |
| Build mutex | `/home/deploy/repo/lodgers-ai/.build-lock`, `tysonxdev:tysonxdev`, mode 0660 | Required for build/publish work |
| Containers | Docker 29.6.1, linux/arm64 | Disposable PostgreSQL validation is technically available |
| Runner | `actions.runner.TysonX-Teoranta.tysonx-dev-org.service`, active/running | This is the primary runner |
| systemd | System manager available; user manager unavailable (`No medium found`) | Candidate watchdog needs a system-manager installation path |
| GitHub | Dev `gh` login is valid for Git operations but its PAT cannot read Actions runs (HTTP 403) | Runner diagnostics are available; Actions API evidence needs a suitably scoped token |
| Host health | systemd reports degraded because `certbot.service` and `clamav-daemon.service` are failed; runner and Lodgers dev service are active | Record separately; not treated as a Tier 0 pass/fail without causal evidence |
| Current relevant processes | Only runner service processes; no `dotnet-coverage`, `testhost`, `vstest`, or dump collector found | No active wedge at audit time |

## Safety boundary

`tysonx-dev` is the primary runner. Destructive watchdog scenarios are prohibited there. The destructive battery
may run only on a separately registered disposable runner that matches this audit's OS, architecture, SDK,
Coverlet/testhost, systemd/cgroup, CPU, and memory profile; has no deployment credentials; and has no normal CI
labels. Primary promotion is restricted to non-destructive canaries after the repeated isolated battery passes.

## Readiness verdict

- Ready: code preparation, static/self-tests, ordinary mutex-controlled builds, Docker PostgreSQL development,
  and non-destructive inspection on dev.
- Not yet ready: destructive watchdog acceptance or primary installation. No disposable runner has been
  identified or proven credential-free.
- Enforcement remains disabled until every Tier 0 acceptance scenario has evidence.

## Readiness update — 2026-08-05

- The destructive watchdog battery passed three repetitions on disposable GitHub-hosted
  `ubuntu-24.04-arm` capacity matching 4 CPU, 15 GiB, ARM64, systemd, and SDK 10.0.110. The disposable runner had
  no deployment credentials or normal self-hosted labels. Exact watchdog commit: `10576d0`.
- The proven watchdog was installed on the primary through a root-owned, least-privilege entrypoint and sudoers
  rule. A non-destructive runner-owned canary passed and left no scope or descendant behind.
- No destructive watchdog scenario ran on `tysonx-dev`.
- The ordinary primary runner coverage proof remains a required promotion checkpoint and must be recorded before
  blocking watchdog enforcement is selected by the Lodgers caller.
- TOTP gate installation remains an operator action under the existing Pulse root-boundary policy. The reviewed
  root installation payload reuses the existing seed; automation has not replaced or exposed it.
- Current disposable PostgreSQL acceptance run `30971253097` passed both migration routes plus the
  fixture-generation and EF script-generation fail-closed cases. It used the immutable PostgreSQL 18 manifest
  `sha256:3f55f8895c4ed50603e2fbdfc72fffeeaba3173321fee5cb825bbbeb30d9d854`.
