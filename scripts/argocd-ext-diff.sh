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
# DIFF_CONTEXT (default 1) = lines of unchanged context per hunk.
# Exit status is diff's (0 same, 1 differ, >1 error), as argocd expects.
set -uo pipefail

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

diff -U"${DIFF_CONTEXT:-1}" "$1" "$2" | awk -v label="${label}" '
NR == 1 { next }
NR == 2 { n = $2; sub(/.*\//, "", n); print "=== RESOURCE: " (label != "" ? label : n); next }
/^@@/   { print "@@"; next }
/^-/    { print "REMOVED | " substr($0, 2); next }
/^\+/   { print "ADDED   | " substr($0, 2); next }
/^ /    { print "        | " substr($0, 2); next }
        { print }
'
exit "${PIPESTATUS[0]}"
