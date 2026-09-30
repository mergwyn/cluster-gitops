#!/usr/bin/env bash

set -euo pipefail

# Colors for scannable output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Ensure required tools are installed
for cmd in helmfile yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}Error:${NC} Required command '$cmd' is not installed."
    exit 1
  fi
done

echo -e "${BLUE}=== Scanning for app-template helmfiles across directory tree ===${NC}\n"

declare -a AFFECTED_APPS=()
declare -a UNCHANGED_APPS=()
declare -a ERRORED_APPS=()

# Find all helmfile configs (yaml or gotmpl)
while IFS= read -r helmfile_path; do
  app_dir=$(dirname "$helmfile_path")
  app_name=$(basename "$app_dir")

  # Check if this helmfile explicitly references app-template
  if ! grep -qE "chart:.*app-template|chart:.*bjw-s" "$helmfile_path"; then
    continue
  fi

  echo -e "Checking ${YELLOW}${app_name}${NC} (${app_dir})..."

  # Run helmfile diff inside the app directory
  # Capturing stderr & stdout to parse results
  if diff_output=$(cd "$app_dir" && helmfile diff --color=false 2>&1); then
    # Filter out common non-substantive lines (like 'Comparing...')
    actual_changes=$(echo "$diff_output" | grep -vE "^(Comparing|Processing|Building|Loaded)" | grep -v "^$" || true)

    if [[ -z "$actual_changes" ]]; then
      echo -e "  └─ ${GREEN}No changes detected.${NC}"
      UNCHANGED_APPS+=("${app_name}")
    else
      echo -e "  └─ ${RED}Changes detected!${NC}"

      # Identify trigger reasons
      triggers=()
      echo "$actual_changes" | grep -q -i "topologySpreadConstraints" && triggers+=("TopologySpreadConstraints")
      echo "$actual_changes" | grep -q -i "NetworkPolicy" && triggers+=("NetworkPolicy")

      if [[ ${#triggers[@]} -gt 0 ]]; then
        trig_str="$(IFS=', '; echo "${triggers[*]}")"
        AFFECTED_APPS+=("${app_name} [${trig_str}]")
      else
        AFFECTED_APPS+=("${app_name} [Template Changes]")
      fi

      # Save full diff log
      mkdir -p ./diff-logs
      echo "$diff_output" > "./diff-logs/${app_name}.diff"
    fi
  else
    echo -e "  └─ ${RED}Error running helmfile diff!${NC}"
    ERRORED_APPS+=("${app_name}")
    mkdir -p ./diff-logs
    echo "$diff_output" > "./diff-logs/${app_name}-error.log"
  fi

done < <(find . -type f \( -name "helmfile.yaml" -o -name "helmfile.yaml.gotmpl" \) -not -path "*/.git/*")

echo -e "\n${BLUE}==========================================${NC}"
echo -e "${BLUE}             SUMMARY REPORT               ${NC}"
echo -e "${BLUE}==========================================${NC}\n"

echo -e "${GREEN}Unchanged Apps (${#UNCHANGED_APPS[@]}):${NC}"
for app in "${UNCHANGED_APPS[@]}"; do
  echo "  - $app"
done

if [[ ${#ERRORED_APPS[@]} -gt 0 ]]; then
  echo -e "\n${RED}Errored Apps (${#ERRORED_APPS[@]}):${NC}"
  for app in "${ERRORED_APPS[@]}"; do
    echo "  - $app"
  done
fi

echo -e "\n${YELLOW}Affected Apps Needing Review (${#AFFECTED_APPS[@]}):${NC}"
for app in "${AFFECTED_APPS[@]}"; do
  echo "  - $app"
done

if [[ ${#AFFECTED_APPS[@]} -gt 0 || ${#ERRORED_APPS[@]} -gt 0 ]]; then
  echo -e "\nDetailed outputs saved to ${BLUE}./diff-logs/${NC}"
fi

