#!/usr/bin/env bash
# doctor-check.sh
#
# Runs `helmfile doctor` against changed app(s) in a PR, using the same
# --api-versions / --kube-version flags your ArgoCD CMP plugin would
# normally inject, and using the same critical-package list already
# defined in renovate/automerge.json (single source of truth, not
# duplicated here).
#
# Expects to run with:
#   KUBECONFIG              pointed at the scoped helmfile-doctor kubeconfig
#   HELMFILE_LLM_BASE_URL   e.g. http://<ollama-host>:11434/v1
#   HELMFILE_LLM_API_KEY    dummy value, Ollama ignores it
#   HELMFILE_LLM_MODEL      e.g. llama3.1 (whatever you're running locally)
#
# Usage: ./doctor-check.sh <base-ref>
#   e.g. ./doctor-check.sh origin/main

set -euo pipefail

BASE_REF="${1:?Usage: doctor-check.sh <base-ref>}"
AUTOMERGE_CONFIG="renovate/automerge.json"
REPORT_DIR="doctor-reports"
STEPS_STATUS=0

mkdir -p "${REPORT_DIR}"

# --- 1. What changed? ------------------------------------------------------
# App definitions live at kubernetes/apps/<category>/<app-name>/... — the
# top-level clusters/ directory is only per-environment variables, not app
# config, so it's not a useful trigger path.
CHANGED_FILES=$(git diff --name-only "${BASE_REF}"...HEAD)

if ! echo "${CHANGED_FILES}" | grep -q '^kubernetes/apps/'; then
  echo "No changes under kubernetes/apps/ — nothing for doctor to check."
  echo "run=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi
echo "run=true" >> "${GITHUB_OUTPUT:-/dev/null}"

# kubernetes/apps/<category>/<app-name>/... -> app name is the 4th segment
CHANGED_APPS=$(echo "${CHANGED_FILES}" \
  | grep '^kubernetes/apps/' \
  | awk -F/ '{print $4}' \
  | sort -u)

if [[ -z "${CHANGED_APPS}" ]]; then
  echo "Matched kubernetes/apps/ but couldn't extract an app name — check the awk pattern above against your layout." >&2
  exit 1
fi

echo "Changed apps: ${CHANGED_APPS}"

# --- 2. Replicate what ArgoCD's CMP plugin normally injects -----------------
echo "Discovering KUBE_API_VERSIONS and KUBE_VERSION from the live cluster..."
KUBE_API_VERSIONS=$(kubectl api-versions | paste -sd, -)
RAW_KUBE_VERSION=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
KUBE_VERSION_SANITISED="${RAW_KUBE_VERSION%%+*}"   # strip +k3s1, matches generate script

echo "KUBE_API_VERSIONS=${KUBE_API_VERSIONS}"
echo "KUBE_VERSION=${KUBE_VERSION_SANITISED}"

# --- 3. Is any changed app on the "manual review" critical list? ------------
# Pulled from renovate/automerge.json so this never drifts out of sync with
# your actual tiering.
CRITICAL_PACKAGES=$(jq -r '
  .packageRules[]
  | select(.description | test("Manual review"; "i"))
  | .matchPackageNames[]
' "${AUTOMERGE_CONFIG}")

IS_CRITICAL=false
for app in ${CHANGED_APPS}; do
  for pkg in ${CRITICAL_PACKAGES}; do
    pkg_clean=$(echo "${pkg}" | tr -d '/')   # strip regex slashes, e.g. /longhorn/ -> longhorn
    if [[ "${app}" == *"${pkg_clean}"* ]]; then
      IS_CRITICAL=true
    fi
  done
done

echo "critical=${IS_CRITICAL}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "Critical-tier app in this PR: ${IS_CRITICAL}"

# --- 4. Run doctor per changed app ------------------------------------------
for app in ${CHANGED_APPS}; do
  echo "--- Running helmfile doctor for app=${app} ---"
  REPORT_FILE="${REPORT_DIR}/${app}.json"

  if ! helmfile -l app="${app}" doctor \
      --args "--api-versions ${KUBE_API_VERSIONS} --kube-version ${KUBE_VERSION_SANITISED}" \
      --output json > "${REPORT_FILE}"; then
    echo "doctor failed to run for ${app} (non-LLM failure, e.g. render error)" >&2
    STEPS_STATUS=1
    continue
  fi

  HIGH_RISKS=$(jq '[.risks[]? | select(.severity == "HIGH")] | length' "${REPORT_FILE}" 2>/dev/null || echo 0)
  echo "${app}: ${HIGH_RISKS} HIGH risk item(s)"

  # Only fail the check for HIGH risks on the non-critical (automerge) tier.
  # Critical-tier apps are already gated by automerge:false — doctor's job
  # there is to inform review, not block, so we don't fail the job for them.
  if [[ "${HIGH_RISKS}" -gt 0 && "${IS_CRITICAL}" == "false" ]]; then
    echo "HIGH risk detected on an automerge-eligible app — failing check."
    STEPS_STATUS=1
  fi
done

exit "${STEPS_STATUS}"
