#!/usr/bin/env bash
# crd-schema-diff.sh LIVE DESIRED
#
# Structural diff of two CRD manifests. Descriptions, labels, annotations and
# status are stripped first, so wording changes and chart-version bumps
# disappear. Output uses the same REMOVED / ADDED labels as argocd-ext-diff.
#
#   - Every REMOVED line is shown (removals are what break existing resources).
#   - ADDED lines are shown only if they look like constraints (required, rule,
#     enum, default, served/storage, ...). New optional fields are counted only.
#
# CRD_DIFF_MAX_LINES (default 80) caps each section.
# Exit: 0 no structural change, 1 changed, 2 error (needs mikefarah yq v4).
set -uo pipefail

MAX="${CRD_DIFF_MAX_LINES:-80}"
KEYS='required:|rule:|message:|default:|enum:|served:|storage:|deprecated|x-kubernetes-|maxLength|minLength|maximum|minimum|pattern:|nullable'

norm() {
  yq eval 'del(.. | .description?) | del(.metadata.labels) | del(.metadata.annotations) | del(.status)' "$1"
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

norm "$1" > "${tmp}/live" 2>/dev/null || exit 2
norm "$2" > "${tmp}/desired" 2>/dev/null || exit 2

diff "${tmp}/live" "${tmp}/desired" > "${tmp}/d"
rc=$?
[[ ${rc} -le 1 ]] || exit 2
[[ ${rc} -eq 1 ]] || exit 0

grep '^< ' "${tmp}/d" | sed 's/^< //' > "${tmp}/removed" || true
grep '^> ' "${tmp}/d" | sed 's/^> //' > "${tmp}/added" || true
grep -E "${KEYS}" "${tmp}/added" > "${tmp}/added_key" || true

nr=$(wc -l < "${tmp}/removed" | tr -d ' ')
na=$(wc -l < "${tmp}/added" | tr -d ' ')
nk=$(wc -l < "${tmp}/added_key" | tr -d ' ')

# Nothing left after normalisation, e.g. description-only changes.
[[ $((nr + na)) -gt 0 ]] || exit 0

echo "SCHEMA CHANGES (descriptions, labels, annotations ignored): ${nr} removed, ${na} added (${nk} constraint lines shown)"

show() { # label file
  head -n "${MAX}" "$2" | sed "s/^/$1 | /"
  local total
  total=$(wc -l < "$2" | tr -d ' ')
  if [[ ${total} -gt ${MAX} ]]; then
    echo "... $((total - MAX)) more not shown"
  fi
}

show "REMOVED" "${tmp}/removed"
show "ADDED  " "${tmp}/added_key"
exit 1
