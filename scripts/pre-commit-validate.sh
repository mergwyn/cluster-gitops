#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_DIR="00-bootstrap"

check_bootstrap_relative_paths() {
  echo "🔍 checking bootstrap relative paths"
  echo "🔍 NOT CHECKING BOOTSTRAP RELATIVE PATHS"
  return

  repo_root="$(git rev-parse --show-toplevel)"

  find ${BOOTSTRAP_DIR} -type f \( -name 'helmfile.yaml' -o -path '*/helmfile.d/*.yaml' \) |
  while read -r hf; do
    hf_dir="$(dirname "$hf")"

    yq e '
      [
        .bases[]?,
        .helmfiles[]?,
        .values[]?,
        .files[]?
      ]
      | .[]
      | select(type == "string")
      | select(startswith("./") or startswith("../"))
    ' "$hf" | while read -r rel; do
      abs="$(realpath -m "$hf_dir/$rel")"

      # must exist
      if [[ ! -e "$abs" ]]; then
        echo "❌ $hf references missing path: $rel"
        echo "   → resolved to: $abs"
        exit 1
      fi

      # must stay inside repo
      if [[ "$abs" != "$repo_root"* ]]; then
        echo "❌ $hf path escapes repo root: $rel"
        echo "   → resolved to: $abs"
        exit 1
      fi
    done
  done
}

FAILED=0

command -v yq >/dev/null || {
  echo "❌ yq (mikefarah/yq v4) is required for pre-commit checks"
  exit 1
}

echo "🔍 Running GitOps pre-commit checks..."

# Only check files staged for commit
FILES=$(git diff --cached --name-only)

# --- app.yaml validation ---
for app in $(echo "$FILES" | grep -E '(^|/)app\.yaml$' || true); do
  echo "→ validating $app"

  # Fail if forbidden keys exist
  FORBIDDEN_KEYS=$(yq e '
    keys
    | map(select(. != "wave"))
    | .[]
  ' "$app" || true)

  if [[ -n "$FORBIDDEN_KEYS" ]]; then
    echo "❌ $app contains forbidden keys:"
    echo "$FORBIDDEN_KEYS" | sed 's/^/   - /'
    echo "   Allowed keys: wave"
    FAILED=1
  fi

  # Require wave
  WAVE=$(yq e '.wave // ""' "$app")
  if [[ -z "$WAVE" ]]; then
    echo "❌ $app is missing required key: wave"
    FAILED=1
  fi
done

# --- helmfile namespace validation ---
for hf in $(echo "$FILES" | grep -E '(^|/)helmfile\.ya?ml$' || true); do
  echo "→ validating $hf"

  MISSING_NS=$(yq e '
    .releases[]
    | select(.namespace == null)
    | .name
  ' "$hf" || true)

  if [[ -n "$MISSING_NS" ]]; then
    echo "❌ $hf has releases without namespace:"
    echo "$MISSING_NS" | sed 's/^/   - /'
    FAILED=1
  fi
done

# --- bootstrap relative path escape validation ---

if [[ -d "$BOOTSTRAP_DIR" ]]; then
  echo "→ validating $BOOTSTRAP_DIR for relative path escapes"
  check_bootstrap_relative_paths
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo
  echo "🚫 Pre-commit checks failed"
  echo "💡 Run: hack/normalize-app-metadata.sh"
  exit 1
fi

echo "✅ Pre-commit checks passed"
