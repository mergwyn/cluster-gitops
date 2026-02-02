#!/usr/bin/env bash
set -euo pipefail

ROOTS=("$@")
[[ ${#ROOTS[@]} -gt 0 ]] || ROOTS=(apps base core platform)

command -v yq >/dev/null || {
  echo "❌ yq (mikefarah/yq v4) is required"
  exit 1
}

KEEP_NAMESPACE_IN_APP_YAML=false

for root in "${ROOTS[@]}"; do
  find "$root" -name app.yaml | while read -r app; do
    dir="$(dirname "$app")"
    helmfile="$dir/helmfile.yaml"

    echo "→ processing $dir"

    wave="$(yq e '.wave // ""' "$app")"
    namespace="$(yq e '.namespace // ""' "$app")"

    if [[ -n "$namespace" && -f "$helmfile" ]]; then
      echo "  - moving namespace=$namespace into helmfile"

      yq e -i '
        .releases = (.releases | map(.namespace // "'"$namespace"'"))
      ' "$helmfile"
    fi

    tmp="$(mktemp)"

    if [[ -n "$wave" ]]; then
      yq e ".wave = $wave" -n >>"$tmp"
    fi

    if [[ "$KEEP_NAMESPACE_IN_APP_YAML" == "true" && -n "$namespace" ]]; then
      yq e ".namespace = \"$namespace\"" -n >>"$tmp"
    fi

    if [[ ! -s "$tmp" ]]; then
      echo "❌ $app: no valid keys left (expected at least wave)"
      rm -f "$tmp"
      exit 1
    fi

    mv "$tmp" "$app"
  done
done
