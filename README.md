# ci-templates — canonical TysonX-Teoranta CI/CD (contract C178289477824693)

Canonical single-source of TysonX-Teoranta CI/CD: reusable GitHub Actions workflows
(consume via `@main`) over a deterministic bash spine. This repo is the CICD v2 **dev-stage
gate** — it reconciles the two Phase-1 scaffolds into one tree:

- the orchestration spine + domain registry (was seeded in `tysonx-core/tysonx-cicd/`), and
- the zero-tolerance check logic + reusable workflows (was `ci-templates` PR#4).

`tysonx-core/tysonx-cicd/` is now superseded by this repo (kept in place with a pointer
note); this is the live home.

## Design

- **Thin YAML / fat bash.** GitHub Actions wires triggers + gates and calls the bash
  spine; all logic lives in `cicd/*.sh` so the CI provider can be swapped without
  touching logic.
- **One entry point.** `cicd/checks.sh` is the single dev-stage code-quality gate,
  driven by the central `domains.yml` registry so per-repo gate copies cannot drift.
  It runs a real `dotnet build` under the frozen zero-tolerance analyzer posture +
  comment-density, plus validity/format checks for every other file type the app ships
  (see "The gate is real" below).
- **Native GH-Actions + bash, zero AI at runtime.** The checks are deterministic. The
  only AI in the loop is the code fix an orchestrator dispatches *after* a finding —
  never inside a check.

## Layout

```
ci-templates/
├── README.md                       # this file
├── domains.yml                     # central domain registry (lodgers active; kukuln/tysonx stubs)
├── .github/workflows/
│   ├── _checks-zero-tolerance.yml  # reusable dev-stage gate: thin YAML -> checks.sh, then test+diff-coverage, then retry-tracker
│   └── _dev-automerge.yml          # reusable zero-AI auto-merge for green, in-scope *-dev PRs
└── cicd/
    ├── checks.sh                   # THE central gate (--domain, --repo-root, --scope, --gate|--measure)
    ├── selftest.sh                 # offline unit tests for the parsers (no dotnet/GitHub needed)
    ├── reports/                    # gate output (findings.json/.txt, build.raw.log) — git-ignored
    └── lib/
        ├── common.sh               # strict-mode/logging + minimal domains.yml registry reader
        ├── parse-diagnostics.sh    # MSBuild log -> structured findings (JSON + text)
        ├── comment-density.sh      # custom comment/code ratio heuristic (advisory, .cs only)
        ├── diff-coverage.sh        # Cobertura + git-diff: fails changed lines < min% covered
        ├── retry-tracker.sh        # zt-fail-N label counter; silent step3-elevate at the limit
        ├── json-lint.sh            # .json: validity + canonical jq --indent 2 reformat (hard-gated)
        ├── xml-lint.sh             # .xml/.csproj/.props/.targets: well-formedness + whitespace hygiene
        ├── yaml-lint.sh            # .yml/.yaml: validity (PyYAML) + whitespace hygiene
        ├── editorconfig-lint.sh    # repo-root .editorconfig: structural validity + no dup keys + hygiene
        ├── shell-lint.sh           # .sh: shellcheck clean (thin wrapper, the canonical tool)
        └── md-lint.sh              # .md: unclosed code-fence detection + whitespace hygiene
```

## The gate is real (Phase 1b, extended)

`cicd/checks.sh` runs an **actual `dotnet build`** of the resolved domain's app entry
project under the frozen zero-tolerance analyzer posture and fails on any in-scope
finding — plus validity/hygiene checks for every other file type the app ships.
Proven end-to-end on the real self-hosted runner (not just local fixtures) 2026-07-02.

- **Analyzer set (zero tolerance):** `NoWarn=` (un-suppress CS1591 etc.),
  `GenerateDocumentationFile=true`, `EnforceCodeStyleInBuild=true`, `AnalysisMode=All`,
  `AnalysisLevel=latest`. `--gate` adds `TreatWarningsAsErrors=true`, so ANY IDE/CA/SA/CS
  finding fails the build. No per-rule suppressions.
- **Build target:** only the app entry project (`app_project`), which transitively
  compiles its project references (e.g. `.Client` + `.Shared`). Test projects are NOT
  built by this gate (they run separately via `dotnet test` — see reusable workflow
  below). Generated code (obj/bin, EF Migrations, `*.Designer.cs`, `*.g.cs`,
  `*ModelSnapshot.cs`) is excluded from both the analyzer parse and the density sweep.
- **NuGet audit (NU19xx)** is a security concern owned separately (`NuGetAudit=false`,
  NU\* excluded from the parse) so a new CVE cannot mask code findings.
- **Comment-density** (`.cs` only) is advisory by default (reported, non-blocking);
  `--strict-density` (workflow input `strict_density: true`) makes it fail the gate.
- **JSON** (`.json`) — hard-gated: syntactically valid AND canonically formatted
  (`jq --indent 2`, no key reordering). Safe to fully reformat because JSON has no
  comments to lose.
- **XML family** (`.xml`/`.csproj`/`.props`/`.targets`) — hard-gated: well-formed XML +
  no trailing whitespace / missing final newline. Deliberately NOT a canonical
  reformatter — verified against a real `.csproj` (tabs, UTF-8 BOM, MSBuild `Condition`
  regex) that a naive `xml.dom.minidom` round-trip would mangle.
- **YAML** (`.yml`/`.yaml`) — hard-gated: valid YAML (PyYAML) + same whitespace hygiene
  + no tab indentation. Also deliberately not a reformatter: PyYAML's load+dump
  round-trip drops every comment, which would destroy this repo's own workflow
  comments (pinned-SHA notes, hang-timeout postmortems) on every touch.
- **`.editorconfig`** (repo-root only, not under `app_dirs`) — hard-gated: structural
  validity (`[section]`/`key = value`, no duplicate keys per section, pure awk, no
  library) + whitespace hygiene.
- **Shell scripts** (`.sh`) — hard-gated: `shellcheck` clean (thin wrapper around the
  same tool this repo's own scripts are held to).
- **Markdown** (`.md`) — hard-gated: every fenced code block closed (odd fence-marker
  count = unclosed) + whitespace hygiene. Not a full style linter — heading levels,
  line length etc. are house-style opinion, not defects.
- **SQL** — not checked. lodgers has 0 `.sql` files; nothing to gate yet.

### Where the product code lives

The spine lives here; product code (lodgers) is a **separate checkout**. Point the gate
at it with `--repo-root <path>` (or `CICD_REPO_ROOT`). The gate never guesses a path —
an unset root is a usage error, never a silent pass. In GitHub Actions the reusable
workflow checks out the product repo and passes `--repo-root "$GITHUB_WORKSPACE"`.

```
# whole-repo one-off gate against the real lodgers checkout
cicd/checks.sh --domain lodgers --repo-root /path/to/lodgers-ai --scope whole --gate
# routine per-PR gate (changed files only) vs the domain's dev_base
cicd/checks.sh --domain lodgers --repo-root /path/to/lodgers-ai --scope diff --gate
cicd/checks.sh --list          # list registered domains
cicd/selftest.sh               # offline parser tests
```

## Reusable workflows

- **`_checks-zero-tolerance.yml`** (`workflow_call`, `pull_request` only) — the dev-stage
  gate. Inputs: `domain` (required, a `domains.yml` key), `test_project`, `scope`,
  `min_comment_ratio`, `min_diff_coverage`, `retry_limit`, `strict_density`. It checks
  out the product repo + this spine (`ref: main`), runs `checks.sh` for the code-quality
  verdict, runs `dotnet test` + `diff-coverage.sh` when `test_project` is set, and records
  the pass/fail on the PR via `retry-tracker.sh` (silent `step3-elevate` at the limit).
- **`_dev-automerge.yml`** (`workflow_call`) — deterministic, zero-AI auto-merge. Merges
  only open, non-draft, non-Release/Promote PRs whose base is a `*-dev` branch (allowlist,
  never main/staging/live), that are cleanly mergeable, with every reported check passing.

**Wired live into `lodgers`** (`checks.yml` + `dev-automerge.yml`, `lodgers-dev` branch
protection requires the check + blocks direct pushes, admin-inclusive). kukuln/tysonx
carry thin caller workflows too, but domain status is on-hold/stub in `domains.yml` so
the gate skips them (exit 0) until they have a real solution to build.

## Domain status (honest)

| domain  | repo                        | state    |
|---------|-----------------------------|----------|
| lodgers | `TysonX-Teoranta/lodgers`   | **active** — real solution + app project + app_dirs wired; gate live + branch-protected; proven on the real runner |
| kukuln  | `TysonX-Teoranta/kukuln`    | on-hold — placeholders only; gate skips (exit 0) |
| tysonx  | `TysonX-Teoranta/tysonx`    | stub — placeholders only; gate skips (exit 0) |

## Not delivered here (out of scope / charter)

cosign/vault signing, `promote-*` / sign-publish pieces, systemd-timer pull-agents, and
any staging/live branch, repo, or deploy. Kukuln/tysonx domain wiring waits until those
products have a dev solution to point at. Full spec: `crom-queue/pending/SPEC-C178289477824693-cicd-v2.md`.
