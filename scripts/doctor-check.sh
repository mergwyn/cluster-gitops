#!/usr/bin/env bash
# doctor-check.sh
#
# Runs `helmfile doctor` against changed app(s), diffing the proposed state
# against the LIVE cluster via `argocd app diff` (through helm-diff's
# --diff-tool), using the same --api-versions / --kube-version flags the
# ArgoCD CMP plugin would inject, and the critical-package list from
# renovate/automerge.json (single source of truth).
#
# Modes (auto-detected, override with --mode or DOCTOR_MODE):
#   ci     GITHUB_ACTIONS=true. Diffs the PR head SHA (must be pushed).
#   local  Uploads the app dir with `argocd app diff --local`, so unpushed
#          work is fine. Refused if files outside the app dir changed
#          (shared env etc.): push a WIP branch and use --revision.
#
# Expects:
#   KUBECONFIG              scoped helmfile-doctor kubeconfig
#   ARGOCD_SERVER / ARGOCD_AUTH_TOKEN / ARGOCD_OPTS   argocd CLI access
#   HELMFILE_LLM_BASE_URL   e.g. http://<ollama-host>:11434/v1
#   HELMFILE_LLM_API_KEY    dummy value, Ollama ignores it
#   HELMFILE_LLM_MODEL      e.g. qwen3:8b
#
# Usage: ./doctor-check.sh [options] [<base-ref>]
#   <base-ref>        default: origin/${GITHUB_BASE_REF:-main}
#   --mode ci|local   override auto-detection
#   --revision REF    diff a pushed sha/branch instead of uploading local files
#   --app DIR         check this app dir (repeatable); skips change detection
#   --env NAME        helmfile environment (default: prod)
#   --llm-timeout D   default 180s
#   --full            local mode only: also print each app's full report (all risk
#                     details, affected resources, the diff). Always ignored in CI,
#                     because Actions logs are public. Env: DOCTOR_FULL=1
#   --no-guard        local mode only: skip the 'files changed outside the app dir'
#                     refusal (warns instead). The diff will NOT include those
#                     shared-file changes. Env: DOCTOR_NO_GUARD=1
#
# Other env: ARGO_PROJECT (default argocd; Argo app = <project>/<dir name>),
#            GUARD_IGNORE (regex of changed paths the shared-file guard ignores)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

DIFF_TOOL="${SCRIPT_DIR}/argocd-diff-tool.sh"
AUTOMERGE_CONFIG="renovate/automerge.json"
REPORT_DIR="doctor-reports"
ARGO_PROJECT="${ARGO_PROJECT:-argocd}"
GUARD_IGNORE="${GUARD_IGNORE:-^(doctor-reports/|scripts/|\.github/|\.gitignore$)}"
MODE="${DOCTOR_MODE:-}"
REVISION="${REVISION:-}"
HF_ENV="prod"
LLM_TIMEOUT="180s"
BASE_REF=""
EXPLICIT_APPS=()
NO_GUARD="${DOCTOR_NO_GUARD:-0}"
FULL="${DOCTOR_FULL:-0}"
STEPS_STATUS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --revision) REVISION="$2"; shift 2 ;;
    --app) EXPLICIT_APPS+=("${2%/}"); shift 2 ;;
    --env) HF_ENV="$2"; shift 2 ;;
    --llm-timeout) LLM_TIMEOUT="$2"; shift 2 ;;
    --no-guard) NO_GUARD=1; shift ;;
    --full) FULL=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) BASE_REF="$1"; shift ;;
  esac
done

BASE_REF="${BASE_REF:-origin/${GITHUB_BASE_REF:-main}}"

# --- 0. Environment detection ----------------------------------------------
if [[ -z "${MODE}" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then MODE=ci; else MODE=local; fi
fi
if [[ "${MODE}" != "ci" && "${MODE}" != "local" ]]; then
  echo "--mode must be ci or local" >&2; exit 2
fi

# Full reports may contain live-cluster detail and Actions logs are public, so
# never print them in CI, even if --mode local was forced there.
if [[ "${FULL}" == "1" ]] && [[ "${MODE}" != "local" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "--full ignored: full reports are never printed in CI (logs are public)." >&2
  FULL=0
fi

if [[ -z "${REVISION}" && "${MODE}" == "ci" ]]; then
  # In pull_request runs HEAD is a synthetic merge commit Argo can't fetch.
  if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
    REVISION="$(jq -r '.pull_request.head.sha // empty' "${GITHUB_EVENT_PATH}")"
  fi
  REVISION="${REVISION:-$(git rev-parse HEAD)}"
fi

if ! git rev-parse --verify -q "${BASE_REF}" >/dev/null; then
  echo "Base ref ${BASE_REF} not found (CI needs fetch-depth: 0)." >&2; exit 2
fi

echo "mode=${MODE} base=${BASE_REF} source=${REVISION:-local upload}"

mkdir -p "${REPORT_DIR}"

# --- 1. What changed? ------------------------------------------------------
# App definitions live at kubernetes/apps/<category>/<app-name>/...
resolve_rev() {   # local branch, or its remote-tracking ref after a push
  local r
  for r in "$1" "origin/$1"; do
    if git rev-parse --verify -q "${r}^{commit}" >/dev/null; then echo "${r}"; return 0; fi
  done
  return 1
}

changed_files() {
  local rev_ref
  if [[ "${MODE}" == "ci" ]]; then
    git diff --name-only "${BASE_REF}"...HEAD
  elif [[ -n "${REVISION}" ]] && rev_ref="$(resolve_rev "${REVISION}")"; then
    # Diffing a pushed revision: detect apps from it, not from local WIP files.
    git diff --name-only "${BASE_REF}"..."${rev_ref}"
  else
    # committed + uncommitted (tracked) + untracked, relative to merge-base
    { git diff --name-only "$(git merge-base "${BASE_REF}" HEAD)"
      git ls-files --others --exclude-standard; } | sort -u
  fi
}

CHANGED_FILES="$(changed_files)"
CHANGED_APP_DIRS=""

if [[ ${#EXPLICIT_APPS[@]} -gt 0 ]]; then
  CHANGED_APP_DIRS="$(printf '%s\n' "${EXPLICIT_APPS[@]}" | sort -u)"
else
  if ! echo "${CHANGED_FILES}" | grep -q '^kubernetes/apps/'; then
    echo "No changes under kubernetes/apps/ — nothing for doctor to check."
    echo "run=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
  # Full app directory (helmfile must run from inside it to find helmfile.yaml).
  CHANGED_APP_DIRS="$(echo "${CHANGED_FILES}" \
    | grep '^kubernetes/apps/' \
    | awk -F/ '{print $1"/"$2"/"$3"/"$4}' \
    | sort -u)"
fi
echo "run=true" >> "${GITHUB_OUTPUT:-/dev/null}"

if [[ -z "${CHANGED_APP_DIRS}" ]]; then
  echo "Matched kubernetes/apps/ but couldn't extract an app directory — check the awk pattern against your layout." >&2
  exit 1
fi

echo "Changed app directories: ${CHANGED_APP_DIRS}"

# --- 2. Replicate what ArgoCD's CMP plugin normally injects -----------------
echo "Discovering KUBE_API_VERSIONS and KUBE_VERSION from the live cluster..."
KUBE_API_VERSIONS=$(kubectl api-versions | paste -sd, -)
RAW_KUBE_VERSION=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
KUBE_VERSION_SANITISED="${RAW_KUBE_VERSION%%+*}"   # strip +k3s1, matches generate script

echo "KUBE_API_VERSIONS=${KUBE_API_VERSIONS}"
echo "KUBE_VERSION=${KUBE_VERSION_SANITISED}"

# --- 3. Critical ("manual review") apps, from renovate/automerge.json -------
CRITICAL_PACKAGES=$(jq -r '
  .packageRules[]
  | select(.description | test("Manual review"; "i"))
  | .matchPackageNames[]
' "${AUTOMERGE_CONFIG}")

# Per app (the old version treated one critical app as making the whole PR
# non-blocking).
is_critical() {
  local app="$1" pkg pkg_clean
  for pkg in ${CRITICAL_PACKAGES}; do
    pkg_clean=$(echo "${pkg}" | tr -d '/')   # /longhorn/ -> longhorn
    if [[ "${app}" == *"${pkg_clean}"* ]]; then return 0; fi
  done
  return 1
}

ANY_CRITICAL=false
for app_dir in ${CHANGED_APP_DIRS}; do
  if is_critical "$(basename "${app_dir}")"; then ANY_CRITICAL=true; fi
done
echo "critical=${ANY_CRITICAL}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Critical-tier app in this run: ${ANY_CRITICAL}"

# --- 3a. Full report printer (local only; see --full) -----------------------
print_full() {
  local f="$1"
  echo ""
  echo "  ===== FULL REPORT: ${app} ====="
  jq -r '
    "Model: \(.model // "?")   Duration: \(.duration // "?")",
    "",
    "Summary:",
    (.summary // "none"),
    "",
    "Risks:",
    (if ((.risks // []) | length) == 0 then "  (none)"
     else (.risks[] | "- [\((.level // .severity // "?") | ascii_upcase)] \(.category // "") (\(.source // "llm")): \(.description)\n    Suggestion: \(.suggestion // "-")")
     end),
    "",
    "Affected resources: \((.affected_resources // []) | join(", "))",
    (if .llm_error then "", "LLM error: \(.llm_error)" else empty end),
    "",
    "Diff:",
    (.diff // "")
  ' "${f}"
  echo "  ===== END ====="
}

# --- 3b. Local-upload guard -------------------------------------------------
# `argocd app diff --local` uploads only the app dir, so changes to shared
# files elsewhere would be silently missing from the diff.
guard_local() {
  local app_dir="$1" bad
  bad="$(echo "${CHANGED_FILES}" \
    | grep -Ev "${GUARD_IGNORE}" \
    | grep -Ev "^${app_dir}/" \
    | grep -Ev '^kubernetes/apps/[^/]+/[^/]+/' || true)"
  if [[ -n "${bad}" ]]; then
    if [[ "${NO_GUARD}" == "1" ]]; then
      echo "WARNING (--no-guard): files changed outside ${app_dir} will NOT be in the diff:" >&2
      echo "${bad}" | sed 's/^/  /' >&2
      return 0
    fi
    echo "Refusing local upload for ${app_dir}: files changed outside the app dir:" >&2
    echo "${bad}" | sed 's/^/  /' >&2
    echo "Push a WIP branch and rerun with --revision <branch-or-sha>, or pass --no-guard." >&2
    return 1
  fi
}

# Preload the ollama model so the first doctor run doesn't wait for it to load.
# Only when the endpoint is actually Ollama (hosted APIs like OpenRouter 404 here).
if [[ -n "${HELMFILE_LLM_BASE_URL:-}" && -n "${HELMFILE_LLM_MODEL:-}" ]] \
   && curl -fs --max-time 3 "${HELMFILE_LLM_BASE_URL%/v1}/api/tags" >/dev/null 2>&1; then
  echo "Warming ${HELMFILE_LLM_MODEL}..."
  curl -s "${HELMFILE_LLM_BASE_URL%/v1}/api/generate" \
    -d "{\"model\": \"${HELMFILE_LLM_MODEL}\", \"prompt\": \"hi\", \"keep_alive\": \"30m\"}" > /dev/null || true
fi

# --- 4. Run doctor per changed app -------------------------------------------
for app_dir in ${CHANGED_APP_DIRS}; do
  app=$(basename "${app_dir}")
  argo_app="${ARGO_PROJECT}/${app}"
  echo "--- Running helmfile doctor for ${app_dir} (${argo_app}) ---"
  REPORT_FILE="${REPORT_DIR}/${app}.json"

  if [[ ! -f "${app_dir}/app.yaml" ]]; then
    echo "No app.yaml found for ${app_dir} — cannot determine appNamespace." >&2
    STEPS_STATUS=1
    continue
  fi

  NS=$(yq '.appNamespace' "${app_dir}/app.yaml")
  if [[ -z "${NS}" || "${NS}" == "null" ]]; then
    echo "app.yaml for ${app_dir} has no appNamespace set — refusing to guess." >&2
    STEPS_STATUS=1
    continue
  fi
  echo "Using appNamespace: ${NS}"
  export HELMFILE_NAMESPACE="${NS}"

  if [[ -z "${REVISION}" ]]; then
    if ! guard_local "${app_dir}"; then STEPS_STATUS=1; continue; fi
  fi

  LOCK="$(mktemp -u)"   # wrapper runs argocd once per app, via this lock
  ARGO_LOG="${PWD}/${REPORT_DIR}/${app}.argo.log"
  rm -f "${ARGO_LOG}"

  # Run from inside the app dir: doctor doesn't search subdirectories for
  # helmfile.yaml ("no state file found" otherwise).
  if ! (
    cd "${app_dir}"
    export ARGO_APP="${argo_app}" ARGO_DIFF_LOCK="${LOCK}" ARGO_DIFF_LOG="${ARGO_LOG}"
    # Argo CD owns the objects, so hide any Helm release records (stale ones
    # make helm-diff see "no change" and skip the diff tool entirely). The
    # memory driver needs HELM_MEMORY_DRIVER_DATA to name an existing file or
    # helm exits 1, hence /dev/null. Disable with DOCTOR_HELM_DRIVER= (empty)
    # or pick another driver, e.g. DOCTOR_HELM_DRIVER=secret.
    HELM_DRV="${DOCTOR_HELM_DRIVER-memory}"
    if [[ -n "${HELM_DRV}" ]]; then
      export HELM_DRIVER="${HELM_DRV}"
      if [[ "${HELM_DRV}" == "memory" ]]; then
        export HELM_MEMORY_DRIVER_DATA="${HELM_MEMORY_DRIVER_DATA:-/dev/null}"
      fi
    fi
    if [[ -n "${REVISION}" ]]; then
      export REVISION
    else
      unset REVISION
      export ARGO_LOCAL="${PWD}"
    fi
    helmfile doctor -e "${HF_ENV}" -n "${NS}" --concurrency 1 --force \
      --llm-timeout "${LLM_TIMEOUT}" \
      --log-level warn \
      --args "--api-versions ${KUBE_API_VERSIONS} --kube-version ${KUBE_VERSION_SANITISED}" \
      --diff-args "--diff-tool=${DIFF_TOOL}" \
      --output json
  ) > "${REPORT_FILE}" 2> "${REPORT_DIR}/${app}.err"; then
    rmdir "${LOCK}" 2>/dev/null || true
    echo "doctor failed to run for ${app_dir} (non-LLM failure, e.g. render error); see ${REPORT_DIR}/${app}.err" >&2
    STEPS_STATUS=1
    continue
  fi
  rmdir "${LOCK}" 2>/dev/null || true

  if ! jq -e . "${REPORT_FILE}" >/dev/null 2>&1; then
    echo "  FAIL: doctor produced no valid JSON report; see ${REPORT_DIR}/${app}.err" >&2
    STEPS_STATUS=1
    continue
  fi

  # Did the Argo CD diff actually run? Never report "clean" if it didn't.
  argo_invoked=false; argo_rc=""; argo_bytes=0
  if [[ -f "${ARGO_LOG}" ]]; then
    if grep -q ' invoked ' "${ARGO_LOG}"; then argo_invoked=true; fi
    argo_rc="$(sed -nE 's/.* result rc=([0-9]+) bytes=([0-9]+).*/\1/p' "${ARGO_LOG}" | tail -1)"
    argo_bytes="$(sed -nE 's/.* result rc=([0-9]+) bytes=([0-9]+).*/\2/p' "${ARGO_LOG}" | tail -1)"
  fi
  tmp_report="$(mktemp)"
  jq --argjson inv "${argo_invoked}" --arg rc "${argo_rc}" --arg bytes "${argo_bytes:-0}" \
     '.argo = {invoked: $inv, rc: (if $rc == "" then null else ($rc | tonumber) end), bytes: ($bytes | tonumber)}' \
     "${REPORT_FILE}" > "${tmp_report}" && mv "${tmp_report}" "${REPORT_FILE}"
  rm -f "${tmp_report}"

  if [[ "${argo_invoked}" != "true" ]]; then
    echo "  FAIL: the diff tool was never invoked, so nothing was compared against the live cluster." >&2
    echo "        Likely a stale Helm release record making helm-diff see no change: helm -n ${NS} list" >&2
    STEPS_STATUS=1
    continue
  fi
  if [[ -z "${argo_rc}" || "${argo_rc}" -ge 2 ]]; then
    echo "  FAIL: argocd app diff errored or never finished; see ${ARGO_LOG}" >&2
    STEPS_STATUS=1
    continue
  fi

  CHANGED="$(jq '[(.diff // "") | split("\n")[] | select(test("^(ADDED|REMOVED) "))] | length' "${REPORT_FILE}")"
  if [[ "${CHANGED}" -eq 0 ]]; then
    echo "  ${app}: no diff vs live cluster (argocd rc=${argo_rc}); nothing to review"
    continue
  fi

  # Deterministic severity floor: add rule-based risks a small LLM may under-rate.
  "${SCRIPT_DIR}/severity-floor.sh" "${REPORT_FILE}" \
    || echo "severity floor failed for ${app} (continuing)" >&2

  # The PR-comment step reads .level, so accept .level or .severity, any case.
  HIGH_RISKS=$(jq '[.risks[]? | select(((.level // .severity // "") | ascii_downcase) == "high")] | length' "${REPORT_FILE}" 2>/dev/null || echo 0)
  count_risks() {
    jq --arg l "$1" '[.risks[]? | select(((.level // .severity // "") | ascii_downcase) == $l)] | length' "${REPORT_FILE}"
  }
  echo "  ${app}: ${CHANGED} changed line(s); risks H/M/L = $(count_risks high)/$(count_risks medium)/$(count_risks low)"
  if jq -e '.llm_error' "${REPORT_FILE}" >/dev/null 2>&1; then
    # CI logs are public: only say that it failed, not why.
    if [[ "${MODE}" == "local" ]]; then
      echo "  LLM error: $(jq -r '.llm_error' "${REPORT_FILE}")" >&2
    else
      echo "  LLM call failed" >&2
    fi
  elif [[ "${MODE}" == "local" ]]; then
    echo "  Summary: $(jq -r '.summary // "none"' "${REPORT_FILE}")"
    jq -r '.risks[]? | "  - [\((.level // .severity // "?") | ascii_upcase)] \(.description)"' "${REPORT_FILE}"
  fi
  if [[ "${FULL}" == "1" ]]; then print_full "${REPORT_FILE}"; fi
  echo "${app}: ${HIGH_RISKS} HIGH risk item(s)"

  # Only fail for HIGH risks on the non-critical (automerge) tier. Critical
  # apps are already gated by automerge:false; doctor informs review there.
  if [[ "${HIGH_RISKS}" -gt 0 ]] && ! is_critical "${app}"; then
    echo "HIGH risk detected on an automerge-eligible app — failing check."
    STEPS_STATUS=1
  fi
done

exit "${STEPS_STATUS}"
