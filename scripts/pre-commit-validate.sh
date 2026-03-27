#!/usr/bin/env bash
set -euo pipefail
shopt -s globstar

BOOTSTRAP_DIR="kubernetes/*bootstrap"

FAILED=0

command -v yq >/dev/null || {
  echo "❌ yq (mikefarah/yq v4) is required for pre-commit checks"
  exit 1
}

echo "🔍 Running GitOps pre-commit checks..."

# Only check files staged for commit
FILES=$(git diff --cached --name-only)
if [[ -z ${FILES} ]] ; then
  FILES=$(ls kubernetes/**/app.yaml)
fi

# --- app.yaml validation ---
for app in $(echo "$FILES" | grep -E '(^|/)app\.yaml$' || true); do
  echo "→ validating $app"

  # Fail if forbidden keys exist
  FORBIDDEN_KEYS=$(yq e '
    keys
    | map(select(. != "wave" and . != "appNamespace"))
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

# --- bootstrap relative path escape validation ---

if [[ -d "$BOOTSTRAP_DIR" ]]; then
  echo "→ validating $BOOTSTRAP_DIR for relative path escapes"
  REPO_ROOT="$(git rev-parse --show-toplevel)"

  while read -r rel; do
    file="$(grep -Rnl -- "$rel" "$BOOTSTRAP_DIR" | head -n1)"
    dir="$(dirname "$file")"
    abs="$(realpath -m "$dir/$rel")"

    if [[ ! -e "$abs" ]]; then
      echo "❌ Broken bootstrap reference"
      echo "   File: $file"
      echo "   Ref:  $rel"
      echo "   → $abs does not exist"
      FAILED=1
    elif [[ "$abs" != "$REPO_ROOT"* ]]; then
      echo "❌ Bootstrap path escapes repo"
      echo "   File: $file"
      echo "   Ref:  $rel"
      echo "   → $abs"
      FAILED=1
    fi
  done < <(
    grep -RhoE '^[[:space:]]*-[[:space:]]*(\./|\.\./)[^[:space:]]+' "$BOOTSTRAP_DIR"/helmfile.d \
      | grep -v environments.yaml \
      | sed -E 's/^[[:space:]]*-[[:space:]]*//'
  )

fi

if [[ "$FAILED" -ne 0 ]]; then
  echo
  echo "🚫 Pre-commit checks failed"
  echo "💡 Run: hack/normalize-app-metadata.sh"
  exit 1
fi

echo "✅ Pre-commit checks passed"
