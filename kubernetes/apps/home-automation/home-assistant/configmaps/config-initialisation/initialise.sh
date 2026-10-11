#!/bin/sh
set -e

# 1. Generate the Kopia ignore rules from the version-controlled ConfigMap.
echo "[kopia] Writing .kopiaignore..."
cp /scripts/kopiaignore /config/.kopiaignore

# 2. Synchronize configuration state from GitHub if empty.
cd /config
if [ ! -d .git ]; then
  echo "[git] Initializing config repository from GitHub..."
  mkdir temp-dir
  git clone https://github.com/mergwyn/home-assistant-config temp-dir
  mv temp-dir/.git .
  rm -rf temp-dir
  git checkout .
fi

# 3. Install tools required by the database check and Octopus reconciliation.
echo "[init] Installing required tools..."
apk add --no-cache sqlite jq yq

# 4. Validate the database before Home Assistant starts.
/bin/sh /scripts/check-database.sh

# 5. Reconcile the Octopus Energy API key.
/bin/sh /scripts/sync-octopus-key.sh
