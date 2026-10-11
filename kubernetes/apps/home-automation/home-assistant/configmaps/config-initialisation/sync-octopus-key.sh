#!/bin/sh
set -e

echo "[octopus] Reconciling API key..."
CONFIG_ENTRIES=/config/.storage/core.config_entries

# Read account and API key from secrets.yaml.
ACCOUNT_ID="$(yq -r '.octopus_account' /config/secrets.yaml)"
API_KEY="$(yq -r '.octopus_api_key' /config/secrets.yaml)"

# Validate required secrets.
if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "null" ]; then
  echo "[octopus] ERROR: octopus_account missing from secrets.yaml"
  exit 1
fi
if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
  echo "[octopus] ERROR: octopus_api_key missing from secrets.yaml"
  exit 1
fi

# Check the Home Assistant config entries file.
if [ ! -f "$CONFIG_ENTRIES" ]; then
  echo "[octopus] ERROR: config_entries file missing"
  exit 1
fi

# Require exactly one matching Octopus account.
MATCH_COUNT="$(jq --arg account_id "$ACCOUNT_ID" '
  [
    .data.entries[]
    | select(
        .domain == "octopus_energy"
        and .data.account_id == $account_id
        and .data.kind == "account"
      )
  ] | length
' "$CONFIG_ENTRIES")"
if [ "$MATCH_COUNT" != "1" ]; then
  echo "[octopus] ERROR: Expected one matching account, found $MATCH_COUNT"
  exit 1
fi

# Skip the write if the API key is already correct.
if jq -e \
  --arg account_id "$ACCOUNT_ID" \
  --arg api_key "$API_KEY" '
    any(
      .data.entries[];
      .domain == "octopus_energy"
      and .data.account_id == $account_id
      and .data.kind == "account"
      and .data.api_key == $api_key
    )
  ' "$CONFIG_ENTRIES" > /dev/null; then
  echo "[octopus] API key already up to date"
else
  # Write a replacement in the same directory, preserving permissions.
  TEMP_FILE="$(mktemp /config/.storage/core.config_entries.XXXXXX)"
  trap 'rm -f "$TEMP_FILE"' EXIT

  jq \
    --arg account_id "$ACCOUNT_ID" \
    --arg api_key "$API_KEY" '
      .data.entries |= map(
        if .domain == "octopus_energy"
           and .data.account_id == $account_id
           and .data.kind == "account"
        then .data.api_key = $api_key
        else .
        end
      )
    ' "$CONFIG_ENTRIES" > "$TEMP_FILE"

  FILE_MODE="$(stat -c '%a' "$CONFIG_ENTRIES")"
  chmod "$FILE_MODE" "$TEMP_FILE"
  mv "$TEMP_FILE" "$CONFIG_ENTRIES"
  trap - EXIT

  echo "[octopus] API key updated"
fi

echo "[octopus] Keys and account updated from secret"
