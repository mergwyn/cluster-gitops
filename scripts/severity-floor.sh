#!/usr/bin/env bash
# severity-floor.sh <report.json>
#
# Deterministic risk rules run over the report's .diff (the ADDED/REMOVED
# format produced by argocd-ext-diff.sh). Findings are appended to .risks as
# {level, category:"rule", description, suggestion, source:"rule"}, so small
# LLMs under-rating a change can't hide it. Edit the rules in the awk below.
#
# Rules (HIGH): resource removed; PVC/PV/StorageClass changed; image major
#   version change; privileged / hostNetwork / hostPID / hostIPC /
#   allowPrivilegeEscalation enabled; runAsUser 0; hostPath added;
#   wildcard RBAC added.
# Rules (MEDIUM): hardening (runAsNonRoot / readOnlyRootFilesystem) removed;
#   Ingress/IngressRoute/HTTPRoute/Gateway host changes; any RBAC change;
#   CRD change; replicas set to 0.
set -uo pipefail

report="${1:?usage: severity-floor.sh <report.json>}"
jq -e . "${report}" >/dev/null 2>&1 || exit 0

read -r -d '' AWK_PROG <<'EOF' || true
function emit(level, desc,   key) {
  key = res SUBSEP desc
  if (!(key in seen)) {
    seen[key] = 1
    printf "%s\trule\t%s [%s]\n", level, desc, res
  }
}

function findkind(s) {
  if (match(s, /(PersistentVolumeClaim|PersistentVolume|StorageClass|IngressRoute|Ingress|HTTPRoute|Gateway|ClusterRoleBinding|ClusterRole|RoleBinding|Role|CustomResourceDefinition|StatefulSet|Deployment|DaemonSet|Namespace|Service)/))
    return substr(s, RSTART, RLENGTH)
  return ""
}

# "image: repo:tag@digest" -> "repo<TAB>tag"
function parse_image(v,   i, c, k, repo, tag) {
  sub(/^[[:space:]]*(- )?image:[[:space:]]*/, "", v)
  gsub(/["']/, "", v)
  sub(/@.*/, "", v)
  sub(/[[:space:]]+$/, "", v)
  k = 0
  for (i = length(v); i > 0; i--) {
    c = substr(v, i, 1)
    if (c == "/") break
    if (c == ":") { k = i; break }
  }
  if (k) { repo = substr(v, 1, k - 1); tag = substr(v, k + 1) }
  else   { repo = v; tag = "latest" }
  return repo "\t" tag
}

function major(t) {
  sub(/^v/, "", t)
  if (match(t, /^[0-9]+/)) return substr(t, 1, RLENGTH) + 0
  return "none"
}

function flush(   i, j, rp, ap, rm, am) {
  for (i = 1; i <= nrm; i++) {
    for (j = 1; j <= nadd; j++) {
      split(rmimg[i], rp, "\t")
      split(addimg[j], ap, "\t")
      if (rp[1] == ap[1] && rp[2] != ap[2]) {
        rm = major(rp[2]); am = major(ap[2])
        if (rm != "none" && am != "none" && rm != am)
          emit("high", "image major version change: " rp[1] " " rp[2] " -> " ap[2])
      }
    }
  }
  nrm = 0; nadd = 0
}

/^=== RESOURCE: / {
  flush()
  res = substr($0, 15)
  split(res, rp, " ")
  kind = rp[1]
  if (kind !~ /^[A-Z]/) kind = findkind(res)   # fallback: header was just a filename
  next
}

/^(REMOVED|ADDED) / {
  side = ($1 == "REMOVED") ? "R" : "A"
  c = $0
  sub(/^(REMOVED|ADDED)[ ]*\| /, "", c)

  if (side == "R" && c ~ /^kind: /) emit("high", "resource removed (" substr(c, 7) ")")

  if (kind ~ /^(PersistentVolumeClaim|PersistentVolume|StorageClass)$/)
    emit("high", "storage resource changed (" kind ")")

  if (c ~ /^[[:space:]]*(- )?image:[[:space:]]/) {
    if (side == "R") rmimg[++nrm] = parse_image(c)
    else             addimg[++nadd] = parse_image(c)
  }

  if (side == "A" && c ~ /(privileged|hostNetwork|hostPID|hostIPC|allowPrivilegeEscalation):[[:space:]]*true/)
    emit("high", "security-sensitive setting enabled")
  if (side == "A" && c ~ /^[[:space:]]*runAsUser:[[:space:]]*0[[:space:]]*$/)
    emit("high", "container set to run as root (runAsUser: 0)")
  if (side == "A" && c ~ /^[[:space:]]*(- )?hostPath:/)
    emit("high", "hostPath volume added")
  if (side == "R" && c ~ /(runAsNonRoot|readOnlyRootFilesystem):[[:space:]]*true/)
    emit("medium", "hardening setting removed")
  if (side == "A" && c ~ /(runAsNonRoot|readOnlyRootFilesystem):[[:space:]]*false/)
    emit("medium", "hardening setting disabled")

  if (kind ~ /^(Ingress|IngressRoute|HTTPRoute|Gateway)$/ && c ~ /host/)
    emit("medium", "exposure (hostnames) changed (" kind ")")

  if (kind ~ /^(ClusterRole|ClusterRoleBinding|Role|RoleBinding)$/)
    emit("medium", "RBAC changed (" kind ")")
  if (side == "A" && kind ~ /Role$/ && c ~ /(["']\*["']|^[[:space:]]*- \*[[:space:]]*$)/)
    emit("high", "wildcard RBAC permission added")

  if (kind == "CustomResourceDefinition") emit("medium", "CRD changed")

  if (side == "A" && c ~ /^[[:space:]]*replicas:[[:space:]]*0[[:space:]]*$/)
    emit("medium", "scaled to zero replicas")
}

END { flush() }
EOF

findings="$(jq -r '.diff // ""' "${report}" | awk "${AWK_PROG}")"
[[ -n "${findings}" ]] || exit 0

tmp="$(mktemp)"
if printf '%s\n' "${findings}" | jq -R -s \
     --arg sugg "Rule-based finding (not LLM): review this change before merging." '
       split("\n") | map(select(length > 0) | split("\t")) |
       map({level: .[0], category: .[1], description: .[2], suggestion: $sugg, source: "rule"})' \
     > "${tmp}.rules" \
   && jq --slurpfile r "${tmp}.rules" '.risks = ((.risks // []) + $r[0])' "${report}" > "${tmp}.out"; then
  mv "${tmp}.out" "${report}"
fi
rm -f "${tmp}" "${tmp}.rules" "${tmp}.out"
exit 0
