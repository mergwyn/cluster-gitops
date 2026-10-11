#!/usr/bin/env bash
# KUBECTL_EXTERNAL_DIFF program for `argocd app diff`. Argo calls it once per
# changed resource with two file paths (live, desired).
#
# Emits a unified diff, but with +/- replaced by explicit ADDED / REMOVED
# labels so small LLMs don't mistake YAML list items ("- name: x") for
# removals. Output per resource:
#
#   === RESOURCE: <Kind> <namespace>/<name>   (read from the manifest)
#   @@
#           | unchanged context
#   REMOVED | old line
#   ADDED   | new line
#
# Lines matching DIFF_IGNORE_REGEX are dropped from both sides first, so
# chart-version label bumps don't show up as changes.
#
# CRDs are handed to crd-schema-diff, which compares schema structure only.
#
# DIFF_CONTEXT (default 1) = lines of unchanged context per hunk.
# Exit status is diff's (0 same, 1 differ, >1 error), as argocd expects.
set -uo pipefail

IGNORE_REGEX="${DIFF_IGNORE_REGEX:-^[[:space:]]*(helm\.sh/chart|app\.kubernetes\.io/version):}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Argo's temp files are named after the resource only (e.g. "open-webui"), so
# read Kind and ns/name from the manifest itself.
meta() {
  awk '
    { gsub(/["\047\r]/, "") }
    /^kind:/ && k == "" { k = $2 }
    /^metadata:/ { inm = 1; next }
    inm && /^[^ ]/ { inm = 0 }
    inm && /^  name:/ && n == "" { n = $2 }
    inm && /^  namespace:/ && ns == "" { ns = $2 }
    END { if (k != "") printf "%s %s/%s", k, (ns == "" ? "-" : ns), n }
  ' "$1" 2>/dev/null
}

label="$(meta "$2")"
[[ -n "${label}" ]] || label="$(meta "$1")"

# CRDs: structural diff only. If the helper fails (e.g. yq missing),
# fall through to the normal text diff below.
if [[ "${label}" == CustomResourceDefinition* ]]; then
  out="$("$(dirname "$0")/crd-schema-diff.sh" "$1" "$2")"
  rc=$?
  if [[ ${rc} -le 1 ]]; then
    if [[ -n "${out}" ]]; then
      echo "=== RESOURCE: ${label}"
      echo "${out}"
    fi
    exit "${rc}"
  fi
fi

# Normalise both sides. grep -v exits 1 on empty output, so ignore its status.
grep -Ev "${IGNORE_REGEX}" "$1" > "${tmp}/live" || true
grep -Ev "${IGNORE_REGEX}" "$2" > "${tmp}/desired" || true

diff -U"${DIFF_CONTEXT:-1}" -L "$(basename "$1")" -L "$(basename "$2")" \
  "${tmp}/live" "${tmp}/desired" | awk -v label="${label}" '
NR == 1 { next }
NR == 2 { n = $2; sub(/.*\//, "", n); print "=== RESOURCE: " (label != "" ? label : n); next }
/^@@/   { print "@@"; next }
/^-/    { print "REMOVED | " substr($0, 2); next }
/^\+/   { print "ADDED   | " substr($0, 2); next }
/^ /    { print "        | " substr($0, 2); next }
        { print }
'
exit "${PIPESTATUS[0]}"
