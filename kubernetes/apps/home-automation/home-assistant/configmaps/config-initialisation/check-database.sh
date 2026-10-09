#!/bin/sh
set -e

echo "[guardrail] Checking Home Assistant SQLite DB..."
DB=/config/home-assistant_v2.db
if [ ! -f "$DB" ]; then
  echo "[guardrail] ERROR: DB missing — refusing to start"
  exit 1
fi

echo "[guardrail] Checking schema version..."
if ! sqlite3 "$DB" "PRAGMA schema_version;" > /dev/null; then
  echo "[guardrail] ERROR: Schema version check failed — refusing to start"
  exit 1
fi

echo "[guardrail] Running WAL checkpoint..."
if ! sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null; then
  echo "[guardrail] ERROR: WAL checkpoint failed — refusing to start"
  exit 1
fi

echo "[guardrail] Checking schema..."
if ! sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master;" > /dev/null; then
  echo "[guardrail] ERROR: Schema check failed — refusing to start"
  exit 1
fi
echo "[guardrail] DB OK — validation complete."
