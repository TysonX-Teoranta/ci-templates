#!/usr/bin/env bash
# checks.sh — central CICD v2 zero-tolerance gate (contract C178289477824693).
# One entry point, driven by --domain against domains.yml, so per-repo gate copies
# cannot drift. Runs a real `dotnet build` under a frozen zero-tolerance analyzer
# posture (Roslyn IDE/CA/SA/CS incl. CS1591) over the domain's app project, plus a
# JSON validity/canonical-format check over in-scope .json, plus validity+hygiene
# checks over in-scope .xml/.csproj/.props/.targets, .yml/.yaml and the repo-root
# .editorconfig, and fails on any in-scope finding. Native GH-Actions + bash, zero
# AI at runtime.
# Fleet V3: strict mode, -v verbose, --dry-run, offline-testable via selftest.sh.

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

show_help() {
  cat <<'EOF'
checks.sh — central CICD v2 zero-tolerance gate.

Usage:
  checks.sh --domain <name> --repo-root <product-checkout>
            [--scope diff|whole] [--gate|--measure] [--strict-density]
            [--base <ref>] [--report-dir <dir>] [--config Debug|Release]
            [-v] [--dry-run]
  checks.sh --list      list registered domains and exit

Scope:  diff  (default) only files changed vs the domain's dev_base
        whole all app code (one-off whole-repo cleanup)
Mode:   --gate    (default) warnings-as-errors; non-zero exit on any finding
        --measure tally + report all findings; always exit 0
        --strict-density  make comment-density findings gate-failing (default: advisory)

Exit: 0 clean/measure/list/dry-run/vacuous · 1 findings · 2 usage · 3 missing tool
EOF
}
usage() { [ "${1:-2}" = "0" ] && { show_help; exit 0; }
          err "see --help for usage"; exit "${1:-2}"; }

# --- Defaults ----------------------------------------------------------------
DOMAIN=""
SCOPE="diff"
MODE="gate"
STRICT_DENSITY=0
BASE_REF=""
REPO_ROOT_ARG="${CICD_REPO_ROOT:-}"
CONFIG="Debug"
REPORT_DIR="$CICD_ROOT/reports"
LIST_ONLY=0

# --- Arg parse ---------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)         DOMAIN="${2:-}"; shift 2 ;;
    --scope)          SCOPE="${2:-}"; shift 2 ;;
    --gate)           MODE="gate"; shift ;;
    --measure)        MODE="measure"; shift ;;
    --strict-density) STRICT_DENSITY=1; shift ;;
    --base)           BASE_REF="${2:-}"; shift 2 ;;
    --repo-root)      REPO_ROOT_ARG="${2:-}"; shift 2 ;;
    --report-dir)     REPORT_DIR="${2:-}"; shift 2 ;;
    --config)         CONFIG="${2:-}"; shift 2 ;;
    --list)           LIST_ONLY=1; shift ;;
    -v|--verbose)     CICD_VERBOSE=1; shift ;;
    --dry-run)        CICD_DRY_RUN=1; shift ;;
    -h|--help)        usage 0 ;;
    *)                err "unknown argument: $1"; usage 2 ;;
  esac
done
export CICD_VERBOSE CICD_DRY_RUN

case "$SCOPE" in diff|whole) ;; *) err "invalid --scope: $SCOPE"; usage 2 ;; esac

# --list — dump the registry and exit clean.
if [ "$LIST_ONLY" = "1" ]; then
  log "registered domains ($(registry_file)):"
  while IFS= read -r d; do
    printf '  %-10s repo=%-28s status=%s\n' \
      "$d" "$(domain_field "$d" repo)" "$(domain_field "$d" status)"
  done < <(domains_list)
  exit 0
fi

# --- Resolve + validate the target domain ------------------------------------
[ -n "$DOMAIN" ] || { err "--domain is required (or use --list)"; usage 2; }
domain_exists "$DOMAIN" || die "unknown domain: $DOMAIN (see --list)" 2

REPO="$(domain_field "$DOMAIN" repo)"
SOLUTION="$(domain_field "$DOMAIN" solution)"
APP_PROJECT="$(domain_field "$DOMAIN" app_project)"
APP_DIRS_RAW="$(domain_field "$DOMAIN" app_dirs)"
STATUS="$(domain_field "$DOMAIN" status)"
[ -n "$BASE_REF" ] || BASE_REF="$(domain_field "$DOMAIN" dev_base)"

log "domain=$DOMAIN repo=$REPO status=$STATUS scope=$SCOPE mode=$MODE base=${BASE_REF:-<unset>}"

if [ "$STATUS" != "active" ]; then
  warn "domain '$DOMAIN' status=$STATUS — not active; skipping gate (exit 0)."
  exit 0
fi

# A wired, active domain needs a solution + app project + app_dirs to build.
[ -n "$SOLUTION" ]     || die "domain '$DOMAIN' active but 'solution' unset in registry" 2
[ -n "$APP_PROJECT" ]  || die "domain '$DOMAIN' active but 'app_project' unset in registry" 2
[ -n "$APP_DIRS_RAW" ] || die "domain '$DOMAIN' active but 'app_dirs' unset in registry" 2
read -r -a APP_DIRS <<< "$APP_DIRS_RAW"

# --- Resolve the product-repo checkout (never guessed) -----------------------
[ -n "$REPO_ROOT_ARG" ] || die "product checkout not set: pass --repo-root <path> (or CICD_REPO_ROOT) pointing at the '$DOMAIN' repo working tree" 2
DOMAIN_ROOT="$(cd "$REPO_ROOT_ARG" 2>/dev/null && pwd)" || die "--repo-root does not exist: $REPO_ROOT_ARG" 2
BUILD_TARGET="$DOMAIN_ROOT/$APP_PROJECT"
[ -f "$BUILD_TARGET" ] || die "app project not found under checkout: $BUILD_TARGET (wrong --repo-root for domain '$DOMAIN'?)" 2

# Zero-tolerance MSBuild posture as explicit global properties so the committed dev
# config (warning-tolerant) is untouched and the gate stays reversible + self-contained:
#   NoWarn=                          un-suppress CS1591 (missing XML doc) etc.
#   GenerateDocumentationFile=true   CS1591 actually evaluated
#   EnforceCodeStyleInBuild=true     IDE* style rules run in build
#   AnalysisMode=All / Level=latest  full CA/SA analyzer set
#   NuGetAudit=false                 dependency-vuln audit (NU19xx) is security-owned,
#                                    kept out of the code gate.
# TreatWarningsAsErrors is toggled per run-mode below.
ZEROTOL_PROPS=(
  /p:NoWarn=
  /p:NuGetAudit=false
  /p:GenerateDocumentationFile=true
  /p:EnforceCodeStyleInBuild=true
  /p:AnalysisMode=All
  /p:AnalysisLevel=latest
)

require dotnet
require git
require jq

mkdir -p "$REPORT_DIR"
RAW_LOG="$REPORT_DIR/build.raw.log"
FINDINGS_JSON="$REPORT_DIR/findings.json"
FINDINGS_TXT="$REPORT_DIR/findings.txt"

log "checkout=$DOMAIN_ROOT target=$APP_PROJECT config=$CONFIG report=$REPORT_DIR"

# --- Scope resolution --------------------------------------------------------
# Build an exact diff-filter regex from the registry app_dirs (escape dots). A git
# `**` pathspec is unreliable (default pathspec magic lets `*` cross `/`), so we list
# changed paths and filter in bash against this anchored alternation.
DIFF_RE=""
for d in "${APP_DIRS[@]}"; do
  DIFF_RE+="${DIFF_RE:+|}$(printf '%s' "$d" | sed 's/[.]/\\./g')"
done
DIFF_RE="^(${DIFF_RE})/.*\.(cs|razor|json|xml|csproj|props|targets|yml|yaml)$"

IN_SCOPE_FILES=()
ALL_CHANGED_FILES=()
EDITORCONFIG_CHANGED=0
if [ "$SCOPE" = "diff" ]; then
  if ! git -C "$DOMAIN_ROOT" rev-parse --verify -q "$BASE_REF" >/dev/null; then
    warn "base ref '$BASE_REF' not found in checkout; falling back to whole-repo scope"
    SCOPE="whole"
  else
    mapfile -t ALL_CHANGED_FILES < <(
      git -C "$DOMAIN_ROOT" diff --name-only --diff-filter=ACMR "$BASE_REF"...HEAD 2>/dev/null || true
    )
    mapfile -t IN_SCOPE_FILES < <(printf '%s\n' "${ALL_CHANGED_FILES[@]}" | grep -E "$DIFF_RE" || true)
    printf '%s\n' "${ALL_CHANGED_FILES[@]}" | grep -qx '\.editorconfig' && EDITORCONFIG_CHANGED=1
    log "diff scope: ${#IN_SCOPE_FILES[@]} changed source file(s) vs $BASE_REF"
    if [ "${#IN_SCOPE_FILES[@]}" -eq 0 ] && [ "$EDITORCONFIG_CHANGED" -eq 0 ]; then
      log "no in-scope source changes — gate GREEN by vacuity"
      printf '{"contract":"C178289477824693","domain":"%s","scope":"diff","mode":"%s","total":0,"findings":[]}\n' \
        "$DOMAIN" "$MODE" > "$FINDINGS_JSON"
      : > "$FINDINGS_TXT"
      exit 0
    fi
  fi
fi

# --- Analyzer build ----------------------------------------------------------
# --measure never fails the build (tolerant, count everything); --gate promotes
# warnings to errors so the compile itself is the hard gate, but we ALSO parse the
# log so every finding is reported even when the build aborts early.
if [ "$MODE" = "measure" ]; then
  TWAE=(/p:TreatWarningsAsErrors=false)
else
  TWAE=(/p:TreatWarningsAsErrors=true)
fi

log "restoring app project…"
run dotnet restore "$BUILD_TARGET" /p:NuGetAudit=false >/dev/null 2>&1 || warn "restore reported issues (continuing)"

log "building with zero-tolerance analyzers (this is the slow step)…"
# --no-incremental forces a full recompile of the target + its references so analyzer
# diagnostics ALWAYS emit — an incremental build on a warm tree skips up-to-date
# projects and would silently report zero findings, breaking determinism.
set +e
run dotnet build "$BUILD_TARGET" -c "$CONFIG" --no-restore --no-incremental -v quiet -clp:NoSummary \
  "${ZEROTOL_PROPS[@]}" "${TWAE[@]}" > "$RAW_LOG" 2>&1
BUILD_RC=$?
# NB: common.sh runs `set -uo pipefail` (no -e). We do NOT re-enable -e here — the
# rest of the script checks return codes explicitly and must not abort on the first
# non-zero (e.g. a grep/sed that legitimately matches nothing).

# --- Parse diagnostics into structured findings ------------------------------
# NU19xx (security-reviewed) + generated code are dropped inside parse-diagnostics.sh.
"$CICD_ROOT/lib/parse-diagnostics.sh" "$RAW_LOG" "$SCOPE" "$MODE" \
  "$FINDINGS_JSON" "$FINDINGS_TXT" "${IN_SCOPE_FILES[@]}"

ANALYZER_COUNT=$(sed -n 's/.*"total_analyzer":\([0-9]*\).*/\1/p' "$FINDINGS_JSON" | head -1)
ANALYZER_COUNT=${ANALYZER_COUNT:-0}

# --- Custom comment-density check -------------------------------------------
DENSITY_FAILS=0
DENSITY_TARGETS=()
if [ "$SCOPE" = "whole" ]; then
  for d in "${APP_DIRS[@]}"; do
    [ -d "$DOMAIN_ROOT/$d" ] || continue
    while IFS= read -r f; do DENSITY_TARGETS+=("$f"); done \
      < <(find "$DOMAIN_ROOT/$d" -name '*.cs' \
            -not -path '*/obj/*' -not -path '*/bin/*' -not -path '*/Migrations/*' \
            -not -name '*.g.cs' -not -name '*.Designer.cs' -not -name '*ModelSnapshot.cs' \
            -not -name '*.AssemblyInfo.cs' -not -name '*.GlobalUsings.g.cs' 2>/dev/null)
  done
else
  for f in "${IN_SCOPE_FILES[@]}"; do
    case "$f" in *.cs) DENSITY_TARGETS+=("$DOMAIN_ROOT/$f") ;; esac
  done
fi
if [ "${#DENSITY_TARGETS[@]}" -gt 0 ]; then
  DENSITY_FAILS=$("$CICD_ROOT/lib/comment-density.sh" --report-append "$FINDINGS_TXT" "${DENSITY_TARGETS[@]}") || true
fi

# Comment-density is advisory unless --strict-density: it never fails the gate by
# default (a fixed ratio is a proxy, not a defect), but is always reported.
if [ "$STRICT_DENSITY" = "1" ]; then
  DENSITY_GATE=$DENSITY_FAILS
else
  DENSITY_GATE=0
  [ "$DENSITY_FAILS" -gt 0 ] && \
    warn "comment-density: $DENSITY_FAILS advisory finding(s) — non-blocking (use --strict-density to enforce)"
fi

# --- JSON validity + canonical-formatting check ------------------------------
# Unlike comment-density this is NOT advisory: valid/well-formatted JSON is
# unambiguous (no proxy-metric judgment call), so it always gates.
JSON_FAILS=0
JSON_TARGETS=()
if [ "$SCOPE" = "whole" ]; then
  for d in "${APP_DIRS[@]}"; do
    [ -d "$DOMAIN_ROOT/$d" ] || continue
    while IFS= read -r f; do JSON_TARGETS+=("$f"); done \
      < <(find "$DOMAIN_ROOT/$d" -name '*.json' \
            -not -path '*/obj/*' -not -path '*/bin/*' -not -path '*/node_modules/*' 2>/dev/null)
  done
else
  for f in "${IN_SCOPE_FILES[@]}"; do
    case "$f" in *.json) JSON_TARGETS+=("$DOMAIN_ROOT/$f") ;; esac
  done
fi
if [ "${#JSON_TARGETS[@]}" -gt 0 ]; then
  JSON_FAILS=$("$CICD_ROOT/lib/json-lint.sh" --report-append "$FINDINGS_TXT" "${JSON_TARGETS[@]}") || true
fi

# --- XML-family validity + whitespace-hygiene check (.xml/.csproj/.props/.targets) --
XML_FAILS=0
XML_TARGETS=()
if [ "$SCOPE" = "whole" ]; then
  for d in "${APP_DIRS[@]}"; do
    [ -d "$DOMAIN_ROOT/$d" ] || continue
    while IFS= read -r f; do XML_TARGETS+=("$f"); done \
      < <(find "$DOMAIN_ROOT/$d" \( -name '*.xml' -o -name '*.csproj' -o -name '*.props' -o -name '*.targets' \) \
            -not -path '*/obj/*' -not -path '*/bin/*' 2>/dev/null)
  done
else
  for f in "${IN_SCOPE_FILES[@]}"; do
    case "$f" in *.xml|*.csproj|*.props|*.targets) XML_TARGETS+=("$DOMAIN_ROOT/$f") ;; esac
  done
fi
if [ "${#XML_TARGETS[@]}" -gt 0 ]; then
  XML_FAILS=$("$CICD_ROOT/lib/xml-lint.sh" --report-append "$FINDINGS_TXT" "${XML_TARGETS[@]}") || true
fi

# --- YAML validity + whitespace-hygiene check (.yml/.yaml) -------------------
YAML_FAILS=0
YAML_TARGETS=()
if [ "$SCOPE" = "whole" ]; then
  for d in "${APP_DIRS[@]}"; do
    [ -d "$DOMAIN_ROOT/$d" ] || continue
    while IFS= read -r f; do YAML_TARGETS+=("$f"); done \
      < <(find "$DOMAIN_ROOT/$d" \( -name '*.yml' -o -name '*.yaml' \) \
            -not -path '*/obj/*' -not -path '*/bin/*' 2>/dev/null)
  done
else
  for f in "${IN_SCOPE_FILES[@]}"; do
    case "$f" in *.yml|*.yaml) YAML_TARGETS+=("$DOMAIN_ROOT/$f") ;; esac
  done
fi
if [ "${#YAML_TARGETS[@]}" -gt 0 ]; then
  YAML_FAILS=$("$CICD_ROOT/lib/yaml-lint.sh" --report-append "$FINDINGS_TXT" "${YAML_TARGETS[@]}") || true
fi

# --- Repo-root .editorconfig check --------------------------------------------
# Not under app_dirs (applies repo-wide), so it's scoped independently: whole-scope
# checks it if present, diff-scope checks it only when the diff actually touched it.
EDITORCONFIG_FAILS=0
if { [ "$SCOPE" = "whole" ] || [ "$EDITORCONFIG_CHANGED" -eq 1 ]; } && [ -f "$DOMAIN_ROOT/.editorconfig" ]; then
  EDITORCONFIG_FAILS=$("$CICD_ROOT/lib/editorconfig-lint.sh" --report-append "$FINDINGS_TXT" "$DOMAIN_ROOT/.editorconfig") || true
fi

GATE_TOTAL=$((ANALYZER_COUNT + DENSITY_GATE + JSON_FAILS + XML_FAILS + YAML_FAILS + EDITORCONFIG_FAILS))
log "findings: analyzer=$ANALYZER_COUNT comment-density=$DENSITY_FAILS json=$JSON_FAILS xml=$XML_FAILS yaml=$YAML_FAILS editorconfig=$EDITORCONFIG_FAILS gate-total=$GATE_TOTAL (build rc=$BUILD_RC)"
log "report: $FINDINGS_JSON  |  $FINDINGS_TXT"

# --- Verdict -----------------------------------------------------------------
if [ "$MODE" = "measure" ]; then
  log "MEASURE mode — reporting only, exit 0"
  exit 0
fi
if [ "$GATE_TOTAL" -gt 0 ] || [ "$BUILD_RC" -ne 0 ]; then
  err "ZERO-TOLERANCE GATE FAILED: $GATE_TOTAL finding(s) in scope (build rc=$BUILD_RC)"
  exit 1
fi
log "ZERO-TOLERANCE GATE PASSED — clean"
exit 0
