# CICD v2 — Promotion gates (Phase 4, contract C178289477824693)

This phase delivers the two promotion gates as **thin YAML over fat bash**:

| Piece | File | Gate it enforces |
|-------|------|------------------|
| dev→staging | `.github/workflows/_promote-staging.yml` + `cicd/promote.sh staging` | GH Environment `staging` **required-reviewer email-approval** |
| staging→live | `.github/workflows/_promote-live.yml` + `cicd/totp-verify.sh` + `cicd/promote.sh live` | GH Environment `live` protection **AND** external CROM-PRIVATE TOTP |

Both gates are **structural** — enforced by GH Environment protection + an off-GitHub
TOTP verifier, not by any actor's cooperation. Zero AI at runtime; every script is
shellcheck-clean and offline-testable via `cicd/selftest.sh`.

The signal (`<domain>-<env>-release.json`) is emitted **only after the gate(s) pass**.
Transport of that signal to a bucket (for the env pull-agent) is the `sign-publish`
phase (`cicd/publish.sh` / `cicd/registry.sh`) — out of Phase-4 scope.

---

## ⛔ Out-of-band prerequisites (NOT satisfiable by the dev-box agent/token)

The two items below are **access-gated infra/secret provisioning**. They are outside the
code agent's charter (infra/secrets) and are not satisfiable with the credentials on the
dev box. They are named here precisely so Crom / an org-admin can provision them. The code
above **references** them and fails closed (real BLOCKER, never a fake pass) when absent.

### BLOCKER A — GH Environment protection rules (per domain repo)
- **What:** create GH Environment `staging` (required reviewers = Crom's email) and
  Environment `live` (required reviewers) in **each** per-domain repo:
  `TysonX-Teoranta/lodgers`, `TysonX-Teoranta/tysonx`, `TysonX-Teoranta/kukuln`.
- **Why the dev-box token can't:** the dev-box PAT (`lodgings-ie`, fine-grained) returns
  `403 "Resource not accessible by personal access token"` on
  `GET/PUT repos/<owner>/<repo>/environments/*` for all four repos (verified 2026-07-02).
- **Exact missing scope:** a token with fine-grained **Environments: read & write** +
  **Administration: read & write** on each domain repo (or classic `repo` scope with org
  membership), i.e. an **org-admin / owner** credential. The pulse-held `admin:org` driver
  token is the sanctioned candidate; it must be granted repo-level Environments:write.
- **API to run once granted:**
  `PUT /repos/{owner}/{repo}/environments/staging` with
  `{"reviewers":[{"type":"User","id":<crom_user_id>}]}`, and the same for `live`.
- **Also set:** repo/org **variable** `CICD_TOTP_SEED_FILE` = the on-disk seed PATH on the
  pulse spine runner (see BLOCKER B) — a variable, never a secret (it is only a path).

### BLOCKER B — CROM-PRIVATE live TOTP seed (on the spine, off GitHub)
- **What:** provision Crom's live-release TOTP **seed** (base32) as a mode-600 file on the
  `tysonx-pulse` self-hosted runner (the spine), at the path named by the
  `CICD_TOTP_SEED_FILE` variable (suggested: `/home/deploy/.config/tysonx/crom-live-totp.seed`).
- **Why the agent can't:** the seed is **CROM-PRIVATE** by design — it is not in the
  AI-readable vault (root/private-only) and reading it is outside the code agent's charter.
  The invariant requires the seed to exist **only** on the spine and **never** on GitHub, so
  no AI or GitHub actor can satisfy the live gate.
- **Exact missing secret / path:** `CROM-PRIVATE` live-TOTP seed → file
  `$CICD_TOTP_SEED_FILE` on `tysonx-pulse`, provisioned out-of-band by Crom.
- **Verify once provisioned (on the spine, does not print the seed):**
  `CICD_TOTP_SEED_FILE=<path> cicd/totp-verify.sh --code <current-6-digit> -v` → exit 0.

Until A and B are provisioned by Crom/an org-admin, the workflows are wired and correct but
the gates cannot be exercised end-to-end against the live domain repos. This is a deliberate,
fail-closed BLOCKER — the pipeline never promotes on a missing gate.
