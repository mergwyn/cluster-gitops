#!/usr/bin/env bash

set -euo pipefail

MAIN_BRANCH="main"
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOGS_DIR="${REPO_ROOT}/diff-logs"

mkdir -p "$LOGS_DIR"

echo "=== Running offline git template diff (main vs. renovate) ==="
echo "Repo Root: ${REPO_ROOT}"

while IFS= read -r helmfile_path; do
  abs_helmfile=$(realpath "$helmfile_path")
  git_rel_helmfile="${abs_helmfile#${REPO_ROOT}/}"
  
  app_dir=$(dirname "$abs_helmfile")
  app_name=$(basename "$app_dir")

  # Skip non-app-template helmfiles
  if ! grep -qE "chart:.*app-template|chart:.*bjw-s" "$abs_helmfile"; then
    continue
  fi

  # Discover appNamespace from app.yaml
  app_yaml="${app_dir}/app.yaml"
  target_ns="default"
  if [[ -f "$app_yaml" ]]; then
    extracted_ns=$(yq '.appNamespace // empty' "$app_yaml" 2>/dev/null || true)
    if [[ -n "$extracted_ns" ]]; then
      target_ns="$extracted_ns"
    fi
  fi

  echo "Checking ${app_name} (${git_rel_helmfile}) [namespace: ${target_ns}]..."

  # Fetch main branch helmfile version
  main_content=$(git show "${MAIN_BRANCH}:${git_rel_helmfile}" 2>/dev/null || true)
  if [[ -z "$main_content" ]]; then
    echo "  └─ App not found in ${MAIN_BRANCH}, skipping diff."
    continue
  fi

  (
    cd "$app_dir"
    export HELMFILE_NAMESPACE="${target_ns}"

    # Render Main branch into temp file and clean output
    echo "$main_content" > .helmfile.main.tmp
    main_out=$(helmfile -f .helmfile.main.tmp template --namespace "${target_ns}" 2>/dev/null | sed '/helm\.sh\/chart: app-template-/d; /^[[:space:]]*$/d' || true)
    rm -f .helmfile.main.tmp

    # Render Renovate branch and clean output
    renovate_out=$(helmfile template --namespace "${target_ns}" 2>/dev/null | sed '/helm\.sh\/chart: app-template-/d; /^[[:space:]]*$/d' || true)

    # Diff cleaned manifests
    actual_diff=$(diff -u -w <(echo "$main_out") <(echo "$renovate_out") || true)

    if [[ -n "$actual_diff" ]]; then
      echo "  └─ ⚠️  STRUCTURAL CHANGES DETECTED"
      echo "$actual_diff" > "${LOGS_DIR}/${app_name}.diff"
    else
      echo "  └─ ✅ Clean bump (no structural changes)"
    fi
  )

done < <(find "${REPO_ROOT}" -type f \( -name "helmfile.yaml" -o -name "helmfile.yaml.gotmpl" \) -not -path "*/.git/*")

echo -e "\nSummary diff logs written to: ${LOGS_DIR}/"
