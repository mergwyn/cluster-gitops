#!/usr/bin/env bash
# =============================================================================
# reloader-audit.sh — v3.2.2
#
# Audit what Stakater Reloader is configured to watch, for one workload, one
# namespace, or the whole cluster. READ-ONLY: never mutates cluster state.
#
# Dependencies: bash 4+, kubectl, jq
#
# Usage:
#   reloader-audit.sh -n network
#   reloader-audit.sh -n network -w deployment/traefik
#   reloader-audit.sh -n velero   -w deployment/velero
#   reloader-audit.sh -A
#   reloader-audit.sh -A -k deployment,cronjob
#   reloader-audit.sh -n velero -k job          # include Jobs explicitly
#   reloader-audit.sh -n velero --show-scope    # resolve the RBAC/ns gate
#   reloader-audit.sh -A --show-scope --scope-limit 10
#   reloader-audit.sh -A -o json > audit.json
#
# CHANGELOG
#   v3.2.2  Fix: $ignored | index(.metadata.name) evaluated its argument with
#           $ignored (an array) as input, so the namespace-scope jq aborted with
#           "Cannot index array with string (metadata)". That silently emptied the
#           operator namespace list, which in turn disabled --show-scope namespace
#           filtering (it enumerated every Secret in the cluster) and would have
#           made -A report nothing. Bind the item first. Same shadowing fixed in
#           scope_list ($nsset | index(.ns)), now guarded by if/then/else rather
#           than relying on "or" short-circuiting.
#           parse_trigger now validates the DNS-1123 name shape, so values that
#           merely *look* like names are caught: a live value of
#           "\"minio-s3-conf,idrivee2-s3-conf\"" (literal quotes, e.g. from
#           kubectl annotate with escaped quotes) previously produced two tokens
#           reported as "usable name" — they match nothing, since Reloader
#           compares exact names.
#           recover_names strips surrounding/per-token quotes, so the suggested
#           clean value is usable. --scope-limit 0 gives counts only.
#   v3.2.1  Fix: with "-n NS --show-scope" the operator-scope namespace list was
#           loaded into TARGET_NS, so the run audited every namespace instead of
#           NS. Scope resolution keeps its own OP_NS_LIST.
#           Fix: jq was invoked with --argjson AFTER the program text.
#   v3.2.0  --show-scope / --scope-limit: resolves the ClusterRole labelSelector
#           (matchLabels + matchExpressions -> kubectl -l), resourceNames and the
#           operator namespace scope into concrete object names. The gate is
#           evaluated per referenced resource: coverage gains "rbac-filtered" and
#           an explicit annotation naming an invisible object raises a warn.
#           Multiple selectors are OR'd; -l is used server-side only when there is
#           exactly one. resourceNames is reported but NOT a watch gate (the API
#           server rejects resourceNames on list/watch rules).
#   v3.1.0  Default kinds exclude "job" (-k/-w to include). -A skips namespaces
#           the operator itself excludes, and reports which were skipped.
#   v3.0.3  pod_refs(): "[ ... ] | add" mixed ARRAYS with OBJECTS -> flatten.
#           render_operator(): "join" over .labelSelector (a mapping) -> tojson.
#   v3.0.2  build_index(): plural loop variable vs singular filenames -> singular.
#
# LIMITATION (repeated in the human footer):
#   This infers *eligibility* from live workload annotations, pod specs,
#   ConfigMap/Secret annotations, Reloader flags, RBAC and (with --show-scope) the
#   objects those selectors resolve to. Reloader's in-memory watch state is not
#   observable. Confirm real reloads in the controller log:
#     kubectl -n <ns> logs deploy/<reloader> | grep -i reload
#
# Three distinct filters gate a Secret/ConfigMap (all three are now reported):
#   1. namespace scope   operator --namespace-selector / --namespaces-to-ignore
#   2. RBAC visibility   labelSelector on the ClusterRole rule (a HARD gate: an
#                        object the informer never receives can never trigger)
#   3. per-object opt-out  reloader.stakater.com/ignore / match on the object
# =============================================================================
set -euo pipefail

PROG="${0##*/}"
VERSION="3.2.2"

KINDS_DEFAULT="deployment,statefulset,daemonset,cronjob"
KINDS_ALL="deployment,statefulset,daemonset,cronjob,job"
KINDS="$KINDS_DEFAULT"

NS=""
ALL_NS=0
WORKLOAD=""
CTX=""
OUT="human"
RELOADER_TARGET=""
VERBOSE=0
STRICT=0
SHOW_SCOPE=0
SCOPE_LIMIT=50

WKIND=""
WNAME=""

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
info() { if [[ "$VERBOSE" == 1 ]]; then printf '%s: %s\n' "$PROG" "$*" >&2; fi; }

usage() {
  cat <<EOF
Usage: $PROG [OPTIONS]

Audit stakater/reloader configuration for a workload, a namespace or the cluster.

  -n, --namespace NS        Namespace to audit. Bypasses the operator's own scope.
  -A, --all-namespaces      Audit every namespace, minus the namespaces the
                            Reloader operator itself excludes (its
                            --namespaces-to-ignore / --namespace-selector).
  -w, --workload KIND/NAME  Workload to audit. KIND is optional and defaults to
                            deployment. Accepts deployment, statefulset,
                            daemonset, cronjob, job (singular or plural).
  -k, --kinds LIST          Comma-separated controller kinds to list
                            (default: $KINDS_DEFAULT).
                            Add "job" to include Jobs. Jobs spawned by a CronJob
                            are excluded by default: Reloader annotations belong
                            on the CronJob, not its ephemeral Job runs.
  -c, --context CONTEXT     kubeconfig context (default: current context).
  -o, --output FORMAT       human (default) or json.
  -r, --reloader NS/NAME    Location of the Reloader deployment, if
                            auto-detection fails (default: label
                            app.kubernetes.io/name=reloader, then app=reloader,
                            then reloader-system).
      --show-scope          Also resolve the RBAC labelSelector / resourceNames
                            and the operator's namespace scope into concrete
                            object names. Cluster-wide (independent of -n/-A),
                            so it issues one get secrets -A and one
                            get configmaps -A (metadata only, via go-template).
      --scope-limit N       Max object names listed per kind (default: $SCOPE_LIMIT).
                            Use 0 for counts only.
  -v, --verbose             Progress messages on stderr.
      --strict              Exit 1 when any warn-severity finding is present.
  -h, --help                This help.

Examples:
  $PROG -n network
  $PROG -n velero -w deployment/velero
  $PROG -n velero -k job
  $PROG -n velero --show-scope --scope-limit 0
  $PROG -A -o json > audit.json
EOF
}

# ----------------------------------------------------------------- arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)      NS="${2:-}"; [[ -n "$NS" ]] || die "-n requires a value"; shift 2 ;;
    -A|--all-namespaces) ALL_NS=1; shift ;;
    -w|--workload)       WORKLOAD="${2:-}"; [[ -n "$WORKLOAD" ]] || die "-w requires KIND/NAME"; shift 2 ;;
    -k|--kinds)          KINDS="${2:-}"; [[ -n "$KINDS" ]] || die "-k requires a value"; shift 2 ;;
    -c|--context)        CTX="${2:-}"; [[ -n "$CTX" ]] || die "-c requires a value"; shift 2 ;;
    -o|--output)         OUT="${2:-}"; shift 2 ;;
    -r|--reloader)       RELOADER_TARGET="${2:-}"; shift 2 ;;
    --show-scope)        SHOW_SCOPE=1; shift ;;
    --scope-limit)       SCOPE_LIMIT="${2:-}"; [[ "$SCOPE_LIMIT" =~ ^[0-9]+$ ]] || die "--scope-limit requires a number"; shift 2 ;;
    -v|--verbose)        VERBOSE=1; shift ;;
    --strict)            STRICT=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    --)                  shift; break ;;
    -*)                  die "unknown option: $1 (try --help)" ;;
    *)                   die "unexpected argument: $1 (try --help)" ;;
  esac
done

case "$OUT" in human|json) ;; *) die "invalid -o value: $OUT (expected human or json)" ;; esac
if [[ $ALL_NS -eq 1 && -n "$NS" ]]; then die "-n and -A are mutually exclusive"; fi

IFS=',' read -ra _kind_check <<< "$KINDS"
for _k in "${_kind_check[@]}"; do
  case "$_k" in
    deployment|statefulset|daemonset|cronjob|job) ;;
    *) die "invalid -k value '$_k' (deployment|statefulset|daemonset|cronjob|job)" ;;
  esac
done
unset _k _kind_check

command -v kubectl >/dev/null 2>&1 || die "dependency missing: kubectl"
command -v jq      >/dev/null 2>&1 || die "dependency missing: jq"

KCTL=(kubectl)
if [[ -n "$CTX" ]]; then
  kubectl config get-contexts "$CTX" >/dev/null 2>&1 || die "kubeconfig context not found: $CTX"
  KCTL+=(--context "$CTX")
fi
k() { "${KCTL[@]}" "$@"; }

CURRENT_CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CURRENT_CTX" ]] || die "no current kubectl context; pass -c CONTEXT"
[[ -n "$CTX" ]] || CTX="$CURRENT_CTX"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ jq: audit
cat > "$WORK/audit.jq" <<'JQEOF'
# input: one workload object (Deployment | StatefulSet | DaemonSet | CronJob | Job)
# args : --arg ctx <context> --argjson gauto <bool> --argjson rbacsels <array of selector strings>
# slurp: --slurpfile idx <json>  ([{kind,name,match,ignore,labels}] namespace index)

def trim: gsub("^[ \t\r\n]+|[ \t\r\n]+$"; "");

def truthy: (type == "string") and ((ascii_downcase) == "true");

# Evaluate one kubectl label selector (input) against a label map.
# Supported: k=v, k!=v, "k in (a,b)", "k notin (a,b)", k, !k
def sel_ok($labels):
  if . == "" then true
  else
    (split(",") | map(gsub("^[ ]+|[ ]+$"; "")) | map(select(length > 0))
     | [ .[] |
         if   test("^!")      then ($labels[.[1:]] // null) == null
         elif test(" notin ") then (split(" notin ")) as $p
                                  | (($p[1] | ltrimstr("(") | rtrimstr(")") | split(","))
                                     | index($labels[$p[0]] // "\u0000")) == null
         elif test(" in ")    then (split(" in ")) as $p
                                  | (($p[1] | ltrimstr("(") | rtrimstr(")") | split(","))
                                     | index($labels[$p[0]] // "\u0000")) != null
         elif test("!=")      then (split("!=")) as $p | (($labels[$p[0]] // "") != $p[1])
         elif test("=")       then (split("="))  as $p | (($labels[$p[0]] // "") == $p[1])
         else ($labels[.] != null)
         end
       ]
     | all)
  end;

# Visible if there is no selector at all, or if ANY rule's selector matches (OR).
def rbac_ok($sels; $labels):
  if ($sels | length) == 0 then true else any($sels[]; sel_ok($labels)) end;

def parse_trigger:
  if . == null then []
  elif type != "string" then
    [{ name: (tostring), kind: "suspicious", note: "annotation value is not a string" }]
  else
    (split(",") | map(trim) | map(select(length > 0))) as $t
    | [ $t[] |
        if   test("^(?i:auto)$") then
          { name: ., kind: "auto-token",
            note: "literal \"auto\" is not a resource name; auto-discovery is enabled with reloader.stakater.com/auto: \"true\"" }
        elif test("^[<>|]") then
          { name: ., kind: "suspicious",
            note: "looks like a leaked YAML block-scalar indicator (\"<-\" / \">-\"), not a resource name" }
        elif test("^-") then
          { name: ., kind: "suspicious",
            note: "leading '-' is not valid in a Kubernetes resource name" }
        elif test("[[:space:]]") then
          { name: ., kind: "suspicious",
            note: "embedded whitespace; Reloader matches exact names and whitespace handling is undocumented" }
        elif test("[*?]") then
          { name: ., kind: "suspicious",
            note: "wildcards are not supported; Reloader matches exact names" }
        elif test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$") then
          { name: ., kind: "name" }
        else
          { name: ., kind: "suspicious",
            note: "contains characters that cannot appear in a resource name (quotes, uppercase, underscore …); Reloader matches exact names, so this token matches nothing" }
        end
      ]
  end;

def parse_names:
  if . == null then []
  elif type != "string" then []
  else split(",") | map(trim) | map(select(length > 0)) end;

def recover_names:
  if . == null or (type != "string") then []
  else ( trim | sub("^[<>][~-]?"; "") | trim
         | sub("^[\"']"; "") | sub("[\"']$"; "") | trim
         | parse_names
         | map(trim | sub("^[\"']+"; "") | sub("[\"']+$"; ""))
         | map(select(length > 0)) )
  end;

def container_refs($c; $cls):
  [ ( ($c.env // [])[]
      | select(.valueFrom != null)
      | select(.valueFrom.secretKeyRef != null or .valueFrom.configMapKeyRef != null)
      | { resource: (if .valueFrom.secretKeyRef != null then "secret" else "configmap" end),
          name: (if .valueFrom.secretKeyRef != null then .valueFrom.secretKeyRef.name else .valueFrom.configMapKeyRef.name end),
          source: "env", detail: .name, container: $c.name, containerClass: $cls,
          projectedKeys: [] } ),
    ( ($c.envFrom // [])[]
      | select(.secretRef != null or .configMapRef != null)
      | { resource: (if .secretRef != null then "secret" else "configmap" end),
          name: (if .secretRef != null then .secretRef.name else .configMapRef.name end),
          source: "envFrom",
          detail: (if .prefix != null then ("prefix " + .prefix) else null end),
          container: $c.name, containerClass: $cls, projectedKeys: [] } )
  ] | map(select(.name != null and .name != ""));

# NOTE: container_refs returns an ARRAY while the volume branches each yield a
# single OBJECT, so the result must be flattened, not added.
def pod_refs($pod):
  [ ( ($pod.spec.initContainers // [])[]      | container_refs(.; "initContainer") ),
    ( ($pod.spec.containers // [])[]          | container_refs(.; "container") ),
    ( ($pod.spec.ephemeralContainers // [])[] | container_refs(.; "ephemeralContainer") ),
    ( ($pod.spec.volumes // [])[]
      | select(.secret != null and ((.secret.secretName // "") != ""))
      | { resource: "secret", name: .secret.secretName, source: "volume", detail: .name,
          container: null, containerClass: "pod", projectedKeys: [] } ),
    ( ($pod.spec.volumes // [])[]
      | select(.configMap != null and ((.configMap.name // "") != ""))
      | { resource: "configmap", name: .configMap.name, source: "volume", detail: .name,
          container: null, containerClass: "pod", projectedKeys: [] } ),
    ( ($pod.spec.volumes // [])[]
      | select(.projected != null) as $v
      | ($v.projected.sources // [])[]
      | select(((.secret.name // .configMap.name) // "") != "")
      | { resource: (if .secret != null then "secret" else "configmap" end),
          name: (.secret.name // .configMap.name),
          source: "projectedVolume", detail: $v.name,
          container: null, containerClass: "pod",
          projectedKeys: ((.secret.items // .configMap.items // []) | map(.key)) } ),
    ( ($pod.spec.volumes // [])[]
      | select(.csi != null and (.csi.driver // "") == "secrets-store.csi.k8s.io")
      | select((.csi.volumeAttributes.secretProviderClass // "") != "")
      | { resource: "secretproviderclass", name: .csi.volumeAttributes.secretProviderClass,
          source: "csiVolume", detail: .name, container: null, containerClass: "pod",
          projectedKeys: [] } )
  ] | flatten;

. as $rc
| (($idx[0]) // []) as $idxraw
| ($idxraw | map({ key: ((.kind | ascii_downcase) + "/" + .name), value: . }) | from_entries) as $index
| ( if $rc.kind == "CronJob"
    then ($rc.spec.jobTemplate.spec.template // {})
    else ($rc.spec.template // {}) end ) as $pod
| ($rc.metadata.annotations // {}) as $wann
| ($pod.metadata.annotations // {}) as $pann
| ($wann + $pann) as $ann
| pod_refs($pod) as $refs

| ([ (($wann | keys) + ($pann | keys))[] | select(test("reloader")) ] | unique) as $keys
| [ $keys[] as $k
    | { key: $k,
        value: $ann[$k],
        provenance: ( if (($wann | has($k)) and ($pann | has($k))) then "workload+podTemplate"
                      elif ($wann | has($k)) then "workload"
                      else "podTemplate" end ) } ] as $annEntries

| [ "reloader.stakater.com/auto",
    "secret.reloader.stakater.com/auto",
    "configmap.reloader.stakater.com/auto",
    "reloader.stakater.com/search",
    "secret.reloader.stakater.com/reload",
    "configmap.reloader.stakater.com/reload",
    "secretproviderclass.reloader.stakater.com/reload",
    "secretproviderclass.reloader.stakater.com/auto",
    "secrets.exclude.reloader.stakater.com/reload",
    "configmaps.exclude.reloader.stakater.com/reload",
    "secretproviderclasses.exclude.reloader.stakater.com/reload",
    "reloader.stakater.com/rollout-strategy",
    "deployment.reloader.stakater.com/pause-period",
    "reloader.stakater.com/ignore",
    "reloader.stakater.com/match",
    "reloader.stakater.com/last-reloaded-from",
    "deployment.reloader.stakater.com/paused-at" ] as $known
| [ $annEntries[] | .key as $k | select(($known | index($k)) == null) ] as $unknown

| ($ann["reloader.stakater.com/auto"]) as $autoRaw
| ($ann["secret.reloader.stakater.com/auto"]) as $secAutoRaw
| ($ann["configmap.reloader.stakater.com/auto"]) as $cmAutoRaw
| ($ann["reloader.stakater.com/search"]) as $searchRaw
| ($autoRaw | truthy) as $autoAll
| ($secAutoRaw | truthy) as $secAuto
| ($cmAutoRaw | truthy) as $cmAuto
| ( ($autoRaw != null) and (($autoRaw | type) == "string")
    and (($autoRaw | ascii_downcase) == "false") ) as $autoOff
| ($autoOff | not) as $notOff
| ( $notOff and ($autoAll or $secAuto or $gauto) ) as $autoSecretsEff
| ( $notOff and ($autoAll or $cmAuto or $gauto) ) as $autoCmsEff
| ( ($searchRaw | truthy) and ($autoAll | not) and ($gauto | not) and $notOff ) as $searchMode

| ({ raw: $ann["secret.reloader.stakater.com/reload"] }
   | . + { present: (.raw != null),
           items: (.raw | parse_trigger),
           recovered: (.raw | recover_names) }) as $expS
| ({ raw: $ann["configmap.reloader.stakater.com/reload"] }
   | . + { present: (.raw != null),
           items: (.raw | parse_trigger),
           recovered: (.raw | recover_names) }) as $expC
| ({ raw: $ann["secretproviderclass.reloader.stakater.com/reload"] }
   | . + { present: (.raw != null),
           items: (.raw | parse_trigger),
           recovered: (.raw | recover_names) }) as $expP
| ($ann["secrets.exclude.reloader.stakater.com/reload"] | parse_names) as $exclS
| ($ann["configmaps.exclude.reloader.stakater.com/reload"] | parse_names) as $exclC
| ([ $expS.items[] | select(.kind == "name") | .name ] | unique) as $expSNames
| ([ $expC.items[] | select(.kind == "name") | .name ] | unique) as $expCNames

| ( [ $refs[] | select(.resource == "secret" or .resource == "configmap") | { resource, name } ]
    | unique_by(.resource + "/" + .name) ) as $distinct
| [ $distinct[] as $d
    | ( $index[$d.resource + "/" + $d.name] // null ) as $obj
    | { resource: $d.resource,
        name: $d.name,
        exists: ($obj != null),
        ignored: ((($obj.ignore // "") | ascii_downcase) == "true"),
        match:   ((($obj.match  // "") | ascii_downcase) == "true"),
        rbacVisible: (if $obj == null then null
                      else rbac_ok($rbacsels; ($obj.labels // {})) end),
        excluded: ( if $d.resource == "secret" then ($exclS | index($d.name) != null)
                    else ($exclC | index($d.name) != null) end ) } as $c
    | ( if $c.resource == "secret" then ($expSNames | index($c.name) != null)
        else ($expCNames | index($c.name) != null) end ) as $isExp
    | ( if $c.resource == "secret" then $autoSecretsEff else $autoCmsEff end ) as $isAuto
    | $c + { explicit: $isExp, auto: $isAuto,
             occurrences: [ $refs[] | select(.resource == $c.resource and .name == $c.name)
                            | { source, detail, container, containerClass, projectedKeys } ],
             verdict: (
               if   $c.ignored  then "ignored"
               elif $c.excluded then "excluded-from-auto"
               elif ($c.rbacVisible == false) then "rbac-filtered"
               elif $isExp      then "explicit-annotation"
               elif $isAuto     then (if ($autoAll | not) and $gauto
                                      then "global-auto-reload-all"
                                      else "auto-discovery" end)
               elif ($searchMode and $c.match) then "search+match"
               else "NOT-MONITORED" end ) } ] as $coverage

| [ $coverage[] | select(.resource == "secret")    | .name ] as $refSecretNames
| [ $coverage[] | select(.resource == "configmap") | .name ] as $refCmNames
| [ $expSNames[] | . as $n | select(($refSecretNames | index($n)) == null) ] as $unrefS
| [ $expCNames[] | . as $n | select(($refCmNames    | index($n)) == null) ] as $unrefC

# explicit names that exist but are invisible to Reloader's list/watch
| [ $expSNames[] | . as $n
    | ($index["secret/" + $n] // null) as $o
    | select($o != null and (rbac_ok($rbacsels; ($o.labels // {})) | not))
    | $n ] as $rbacHiddenS
| [ $expCNames[] | . as $n
    | ($index["configmap/" + $n] // null) as $o
    | select($o != null and (rbac_ok($rbacsels; ($o.labels // {})) | not))
    | $n ] as $rbacHiddenC

| ( [ $coverage[] | select(.verdict == "NOT-MONITORED")
      | { severity: "warn", code: "reference-not-monitored",
          message: (.resource + " \"" + .name + "\" is referenced by the pod spec but is not covered by any configured reload trigger"
                    + (if $searchMode then "; search mode is enabled, so it also needs reloader.stakater.com/match: \"true\" on the ConfigMap/Secret" else "" end)) } ]
  + [ $coverage[] | select(.verdict == "rbac-filtered")
      | { severity: "warn", code: "reference-hidden-by-rbac",
          message: (.resource + " \"" + .name + "\" exists but does not match the Reloader ClusterRole labelSelector — Reloader's list/watch never returns it, so no change to it can ever trigger a reload") } ]
  + [ $coverage[] | select(.exists == false)
      | { severity: "warn", code: "reference-missing",
          message: (.resource + " \"" + .name + "\" is referenced by the pod spec but does not exist in namespace " + ($rc.metadata.namespace // "?")) } ]
  + [ $rbacHiddenS[] | . as $n
      | { severity: "warn", code: "annotation-hidden-by-rbac",
          message: ("secret \"" + $n + "\" is named in secret.reloader.stakater.com/reload but does not match the Reloader ClusterRole labelSelector — Reloader's list/watch will never return it, so this annotation is inert") } ]
  + [ $rbacHiddenC[] | . as $n
      | { severity: "warn", code: "annotation-hidden-by-rbac",
          message: ("configmap \"" + $n + "\" is named in configmap.reloader.stakater.com/reload but does not match the Reloader ClusterRole labelSelector — Reloader's list/watch will never return it, so this annotation is inert") } ]
  + [ $expS.items[] | select(.kind != "name")
      | { severity: "warn", code: ("annotation-entry-" + .kind),
          message: ("secret.reloader.stakater.com/reload entry " + (.name | tojson) + " is not a usable resource name — " + .note) } ]
  + [ $expC.items[] | select(.kind != "name")
      | { severity: "warn", code: ("annotation-entry-" + .kind),
          message: ("configmap.reloader.stakater.com/reload entry " + (.name | tojson) + " is not a usable resource name — " + .note) } ]
  + [ $unknown[] | { severity: "info", code: "unknown-reloader-annotation",
      message: ("annotation \"" + .key + "\" contains \"reloader\" but is not a documented Reloader 1.4 key — check for a typo, or for a custom_annotations override that renames the defaults") } ]
  + [ $annEntries[] | select(.provenance == "podTemplate")
      | { severity: "info", code: "annotation-on-pod-template",
          message: (.key + " is set on the pod template only; Reloader reads workload annotations, so verify this is actually honoured") } ]
  + [ $unrefS[] | { severity: "info", code: "explicit-unreferenced",
      message: ("secret \"" + . + "\" is named in secret.reloader.stakater.com/reload but is not referenced by the pod spec (allowed — Reloader watches it regardless)") } ]
  + [ $unrefC[] | { severity: "info", code: "explicit-unreferenced",
      message: ("configmap \"" + . + "\" is named in configmap.reloader.stakater.com/reload but is not referenced by the pod spec (allowed — Reloader watches it regardless)") } ]
  + ( if ($autoRaw != null) and (($autoRaw | type) == "string")
         and (($autoRaw | ascii_downcase) != "true") and (($autoRaw | ascii_downcase) != "false")
       then [{ severity: "warn", code: "non-standard-auto-value",
               message: ("reloader.stakater.com/auto has value " + ($autoRaw | tojson) + "; only \"true\" enables auto-reload, anything else is treated as off") }]
       else [] end )
  + ( if ($searchMode == false) and ($searchRaw != null) and (($searchRaw | type) == "string")
         and (($searchRaw | ascii_downcase) == "true")
       then [{ severity: "info", code: "search-ignored",
               message: "reloader.stakater.com/search: \"true\" is set but auto-reload takes precedence, so search mode is ignored" }]
       else [] end )
  ) as $warnings

| { schemaVersion: 4,
    context: $ctx,
    namespace: ($rc.metadata.namespace // ""),
    kind: ($rc.kind // ""),
    name: ($rc.metadata.name // ""),
    podTemplatePath: (if $rc.kind == "CronJob" then ".spec.jobTemplate.spec.template" else ".spec.template" end),
    rbacSelectorApplied: (($rbacsels | length) > 0),
    annotationEntries: $annEntries,
    unknownReloaderAnnotations: $unknown,
    flags: { autoRaw: $autoRaw,
             autoAll: $autoAll,
             secretsAutoTyped: $secAuto,
             configmapsAutoTyped: $cmAuto,
             searchRequested: $searchRaw,
             searchMode: $searchMode,
             globalAutoReloadAll: $gauto,
             autoOptOut: $autoOff,
             autoSecretsEffective: $autoSecretsEff,
             autoConfigMapsEffective: $autoCmsEff },
    explicit: { secrets: $expS, configmaps: $expC, secretproviderclasses: $expP,
                excludeSecrets: $exclS, excludeConfigMaps: $exclC,
                unreferencedSecrets: $unrefS, unreferencedConfigMaps: $unrefC,
                hiddenByRbacSecrets: $rbacHiddenS, hiddenByRbacConfigMaps: $rbacHiddenC },
    references: $refs,
    coverage: $coverage,
    warnings: $warnings }
JQEOF

# ----------------------------------------------------------------- jq: render
cat > "$WORK/render.jq" <<'JQEOF'
def tag:
  if   . == "NOT-MONITORED"          then "NOT MONITORED"
  elif . == "ignored"                then "ignored (reloader.stakater.com/ignore on the resource)"
  elif . == "excluded-from-auto"     then "excluded from auto"
  elif . == "rbac-filtered"          then "INVISIBLE to Reloader (RBAC labelSelector mismatch)"
  elif . == "explicit-annotation"    then "covered: explicit annotation"
  elif . == "auto-discovery"         then "covered: auto discovery"
  elif . == "global-auto-reload-all" then "covered: global --auto-reload-all"
  elif . == "search+match"           then "covered: search + match"
  else . end;

"",
"  workload     : " + .namespace + "/" + .name + "   (" + .kind + ")",
"  pod template : " + .podTemplatePath,
"  context      : " + (.context // "-"),
"",
"  Reloader annotations",
( if (.annotationEntries | length) == 0
  then "    (no reloader.* annotations — nothing is reloaded for this workload)"
  else (.annotationEntries[] | "    " + .key + " = " + (.value | tojson) + "    [" + .provenance + "]") end ),
"",
"  Trigger mode",
"    auto (all referenced Secrets + ConfigMaps) : " + (if .flags.autoAll then "ENABLED" else "no" end),
"    secret.reloader.stakater.com/auto          : " + (if .flags.secretsAutoTyped then "ENABLED" else "no" end),
"    configmap.reloader.stakater.com/auto       : " + (if .flags.configmapsAutoTyped then "ENABLED" else "no" end),
"    search / match mode                        : " + (if .flags.searchMode then "ENABLED" else "no" end),
"    Reloader --auto-reload-all (cluster-wide)  : " + (if .flags.globalAutoReloadAll then "on" else "off" end),
"    explicit opt-out auto: \"false\"             : " + (if .flags.autoOptOut then "yes" else "no" end),
"    -> effective auto for Secrets              : " + (if .flags.autoSecretsEffective then "YES" else "no" end),
"    -> effective auto for ConfigMaps           : " + (if .flags.autoConfigMapsEffective then "YES" else "no" end),
"",
"  Explicit triggers",
( if (.explicit.secrets.present | not) and (.explicit.configmaps.present | not)
      and (.explicit.secretproviderclasses.present | not)
  then "    (none)"
  else (
    ( if .explicit.secrets.present
      then ( "    secret.reloader.stakater.com/reload = " + (.explicit.secrets.raw | tojson),
             (.explicit.secrets.items[] | "      - " + .name + "   [" + (if .kind == "name" then "usable name" else (.kind + ": " + .note) end) + "]"),
             ( if ((.explicit.secrets.recovered | length) > 0)
                 and (([.explicit.secrets.items[] | select(.kind != "name")] | length) > 0)
               then "      suggested clean value: " + (.explicit.secrets.recovered | join(","))
               else empty end ) )
      else empty end ),
    ( if .explicit.configmaps.present
      then ( "    configmap.reloader.stakater.com/reload = " + (.explicit.configmaps.raw | tojson),
             (.explicit.configmaps.items[] | "      - " + .name + "   [" + (if .kind == "name" then "usable name" else (.kind + ": " + .note) end) + "]"),
             ( if ((.explicit.configmaps.recovered | length) > 0)
                 and (([.explicit.configmaps.items[] | select(.kind != "name")] | length) > 0)
               then "      suggested clean value: " + (.explicit.configmaps.recovered | join(","))
               else empty end ) )
      else empty end ),
    ( if .explicit.secretproviderclasses.present
      then "    secretproviderclass.reloader.stakater.com/reload = " + (.explicit.secretproviderclasses.raw | tojson)
      else empty end ),
    ( if (.explicit.excludeSecrets | length) > 0
      then "    secrets.exclude.reloader.stakater.com/reload = " + (.explicit.excludeSecrets | join(","))
      else empty end ),
    ( if (.explicit.excludeConfigMaps | length) > 0
      then "    configmaps.exclude.reloader.stakater.com/reload = " + (.explicit.excludeConfigMaps | join(","))
      else empty end )
  ) end ),
"",
"  Secret / ConfigMap references found in the pod spec",
( if (.coverage | length) == 0 then "    (none)"
  else ( .coverage[] |
    "    " + (if .resource == "secret" then "SECRET   " else "CONFIGMAP" end) + " " + .name
    + (if .verdict == "NOT-MONITORED" then "   <==" else "   " end) + " " + (.verdict | tag)
    + "   [" + ([.occurrences[] | (.source + (if .container != null then "/" + .container else "" end)
                                    + (if .detail != null then " (" + .detail + ")" else "" end))] | unique | join(", ")) + "]"
    + (if ((.occurrences | map(.projectedKeys | length) | add) // 0) > 0
       then "   projected keys: " + ([.occurrences[] | .projectedKeys[]] | unique | join(", "))
       else "" end)
    + (if .exists | not then "   MISSING IN NAMESPACE" else "" end) ) end ),
"",
"  SecretProviderClass / CSI references",
( if ([.references[] | select(.resource == "secretproviderclass")] | length) == 0 then "    (none)"
  else ([.references[] | select(.resource == "secretproviderclass")] | unique_by(.name)[]
        | "    SPC " + .name + "   [" + .source + " (" + .detail + ")]") end ),
"",
"  Findings",
( if (.warnings | length) == 0 then "    (none)"
  else (.warnings[] | "    [" + (.severity | ascii_upcase) + "] " + .message) end )
JQEOF

# ------------------------------------------------------------ kubectl helpers
build_index() {
  local ns="$1" kind plural tsv
  local parts=()
  for kind in configmap secret; do
    plural="${kind}s"
    tsv="$(k get "$plural" -n "$ns" -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{if .metadata.annotations}}{{index .metadata.annotations "reloader.stakater.com/match"}}{{end}}{{"\t"}}{{if .metadata.annotations}}{{index .metadata.annotations "reloader.stakater.com/ignore"}}{{end}}{{"\t"}}{{range $k,$v := .metadata.labels}}{{$k}}={{$v}};{{end}}{{"\n"}}{{end}}' 2>/dev/null || true)"
    printf '%s\n' "$tsv" | jq -R -s --arg kind "$kind" '
      split("\n") | map(select(length > 0) | split("\t"))
      | map({ kind: $kind,
              name: .[0],
              match: (.[1] // ""),
              ignore: (.[2] // ""),
              labels: ((.[3] // "")
                       | split(";") | map(select(length > 0) | split("="))
                       | map({ key: .[0], value: (.[1:] | join("=")) })
                       | from_entries) })' \
      > "$WORK/index-$ns-$kind.json"
    parts+=("$WORK/index-$ns-$kind.json")
  done
  if ! jq -s 'add' "${parts[@]}" > "$WORK/idx-$ns.json" 2>/dev/null; then
    printf '[]\n' > "$WORK/idx-$ns.json"
    warn "could not build the ConfigMap/Secret index for namespace $ns; references will report as missing"
  fi
}

find_reloader() {
  local json sel
  if [[ -n "$RELOADER_TARGET" ]]; then printf '%s' "$RELOADER_TARGET"; return 0; fi
  for sel in "app.kubernetes.io/name=reloader" "app=reloader"; do
    json="$(k get deployment -A -l "$sel" -o json 2>/dev/null || true)"
    if [[ -n "$json" ]] && [[ "$(jq -r '(.items | length)' <<<"$json" 2>/dev/null || echo 0)" -gt 0 ]]; then
      jq -r '.items[0] | .metadata.namespace + "/" + .metadata.name' <<<"$json"
      return 0
    fi
  done
  json="$(k get deployment -n reloader-system -o json 2>/dev/null || true)"
  if [[ -n "$json" ]] && [[ "$(jq -r '(.items | length)' <<<"$json" 2>/dev/null || echo 0)" -gt 0 ]]; then
    jq -r '.items[0] | .metadata.namespace + "/" + .metadata.name' <<<"$json"
    return 0
  fi
  printf ''
}

OPERATOR_JSON='{"found":false}'

build_operator() {
  local target="$1" ns name dep crb role rolejson
  ns="${target%%/*}"; name="${target##*/}"
  if [[ -z "$ns" || -z "$name" ]]; then return 0; fi
  dep="$(k get deployment -n "$ns" "$name" -o json 2>/dev/null || true)"
  [[ -n "$dep" ]] || return 0

  : > "$WORK/roles.ndjson"
  crb="$(k get clusterrolebinding -o json 2>/dev/null || true)"
  if [[ -n "$crb" ]]; then
    while IFS= read -r role; do
      [[ -z "$role" ]] && continue
      rolejson="$(k get clusterrole "$role" -o json 2>/dev/null || true)"
      [[ -n "$rolejson" ]] || continue
      jq -c --arg n "$role" '
        { kind: "ClusterRole", name: $n,
          rules: [ (.rules // [])[]
                   | select(((.resources // []) | (index("secrets") != null) or (index("configmaps") != null)))
                   | { verbs: (.verbs // []), resources: (.resources // []),
                       labelSelector: (.labelSelector // null), resourceNames: (.resourceNames // null) } ] }' \
        <<<"$rolejson" >> "$WORK/roles.ndjson"
    done < <(jq -r --arg ns "$ns" \
      '(.items // [])[] | select((.subjects // [])[]? | (.namespace // "") == $ns) | .roleRef.name' \
      <<<"$crb" | sort -u)
  fi

  OPERATOR_JSON="$(jq -n --argjson dep "$dep" --slurpfile roles "$WORK/roles.ndjson" --arg ctx "$CTX" '
    ($dep.spec.template.spec.containers // []) as $cs
    | ([ ($cs[] | (.args // [])[]), ($cs[] | (.env // [])[] | (.value // "")) ]) as $flags
    | { found: true,
        context: $ctx,
        namespace: $dep.metadata.namespace,
        deployment: $dep.metadata.name,
        images: [ $cs[] | { container: .name, image: .image } ],
        args: [ $cs[] | (.args // [])[] ],
        env:  [ $cs[] | (.env // [])[] | { name: .name, value: (.value // (if .valueFrom != null then "(valueFrom)" else "" end)) } ],
        namespaceSelector:  ([ $flags[] | select(test("namespace-selector")) ] | first // null),
        namespacesToIgnore: ([ $flags[] | select(test("namespaces-to-ignore")) ] | first // null),
        autoReloadAll:      ([ $flags[] | select(test("auto-reload-all")) ] | first // null),
        reloadOnCreate:     ([ $flags[] | select(test("reload-on-create")) ] | first // null),
        reloadOnDelete:     ([ $flags[] | select(test("reload-on-delete")) ] | first // null),
        reloadStrategy:     ([ $flags[] | select(test("reload-strategy")) ] | first // null),
        watchGlobally:      ([ $flags[] | select(test("watch-globally")) ] | first // null),
        customAnnotationFlags: [ $flags[] | select(test("annotation")) ],
        rbac: $roles }')"
}

# labelSelector (metav1.LabelSelector) -> kubectl -l string
RBAC_SEL_JQ='
  def selstr:
    (((.matchLabels // {}) | to_entries | map("\(.key)=\(.value)"))
     + ((.matchExpressions // []) | map(
         if   .operator == "In"           then "\(.key) in (\(.values | join(",")))"
         elif .operator == "NotIn"        then "\(.key) notin (\(.values | join(",")))"
         elif .operator == "Exists"       then "\(.key)"
         elif .operator == "DoesNotExist" then "!\(.key)"
         else empty end)))
    | join(",");
  [ .rbac[]?.rules[]? | .labelSelector // empty ] | map(selstr) | map(select(length > 0)) | unique'

render_operator() {
  printf '\n%s\n' "--------------------------------------------------------------------------------"
  printf '  Reloader operator (cluster-level scope)\n'
  jq -r '
    if .found != true then
      "    not found — global settings unknown. Point at it with -r NS/NAME if it runs elsewhere."
    else (
      ( "    deployment         : " + .namespace + "/" + .deployment,
        ( .images[] | "    image              : " + .container + " = " + .image ),
        "    args               : " + (if (.args | length) == 0 then "(none)" else (.args | join(" ")) end),
        "    namespaceSelector  : " + (.namespaceSelector // "(not set — default behaviour: watch all namespaces)"),
        "    namespacesToIgnore : " + (.namespacesToIgnore // "(not set)"),
        "    auto-reload-all    : " + (.autoReloadAll // "(not set)"),
        "    reload-on-create   : " + (.reloadOnCreate // "(not set)"),
        "    reload-on-delete   : " + (.reloadOnDelete // "(not set)"),
        "    reload-strategy    : " + (.reloadStrategy // "(not set)"),
        ( if (.customAnnotationFlags | length) > 0
          then ( "    custom annotation flags detected — the documented reloader.stakater.com/* keys may be INACTIVE:",
                 (.customAnnotationFlags[] | "        " + .) )
          else empty end ),
        "    RBAC rules touching Secrets/ConfigMaps (these further restrict what Reloader can watch):",
        ( if (.rbac | length) == 0
          then "        (none found, or the bindings are not readable)"
          else (.rbac[] | "        " + .kind + "/" + .name
                + "  resources=" + (.rules | map(.resources | join("+")) | join("; "))
                + "  labelSelectors=" + ([ .rules[] | (.labelSelector // null) ] | map(if . == null then "none" else tojson end) | unique | join(" | "))
                + "  resourceNames=" + (.rules | map((.resourceNames // []) | join(",")) | unique | join(" | ")))
          end )
      ) )
    end' <<<"$OPERATOR_JSON"
}

render_scope() {
  if [[ "$SCOPE_JSON" == "null" ]]; then return 0; fi
  printf '\n%s\n' "--------------------------------------------------------------------------------"
  printf '  Resolved Reloader scope (cluster-wide; independent of -n/-A)\n'
  jq -r '
    ( if .labelSelector == null
      then "    RBAC labelSelector  : (none — every Secret/ConfigMap in scope is visible to Reloader)"
      else "    RBAC labelSelector  : " + .labelSelector end ),
    ( if .resourceNames == null
      then "    RBAC resourceNames  : (none)"
      else "    RBAC resourceNames  : " + .resourceNames
           + "   (note: resourceNames cannot be used on list/watch rules, so it does not gate watches)" end ),
    "    namespaces in scope : " + ((.namespaces // []) | if length > 20 then ((.[0:20] + ["..."]) | join(",")) else join(",") end),
    ( "    visible Secrets     : " + (.secrets.count | tostring)
      + (if .secrets.truncated and ((.secrets.shown | length) > 0)
         then "   (showing first \(.secrets.shown | length))" else "" end) ),
    ( if (.secrets.shown | length) == 0 then empty else (.secrets.shown[] | "      " + .) end ),
    ( "    visible ConfigMaps  : " + (.configmaps.count | tostring)
      + (if .configmaps.truncated and ((.configmaps.shown | length) > 0)
         then "   (showing first \(.configmaps.shown | length))" else "" end) ),
    ( if (.configmaps.shown | length) == 0 then empty else (.configmaps.shown[] | "      " + .) end ),
    ( if .labelSelector == null
      then "    (no labelSelector is configured, so this is a plain cluster inventory: Reloader can see every Secret/ConfigMap in scope. Use --scope-limit 0 for counts only.)"
      else "    (objects carrying reloader.stakater.com/ignore are omitted; --scope-limit truncates the lists)" end )
  ' <<<"$SCOPE_JSON"
}

# --------------------------------------------------- target kinds, fast fail
if [[ -n "$WORKLOAD" ]]; then
  if [[ "$WORKLOAD" == */* ]]; then WKIND="${WORKLOAD%%/*}"; WNAME="${WORKLOAD#*/}"; else WKIND="deployment"; WNAME="$WORKLOAD"; fi
  case "$WKIND" in
    deployment|deploy|deployments) WKIND="deployment" ;;
    statefulset|sts|statefulsets)  WKIND="statefulset" ;;
    daemonset|ds|daemonsets)       WKIND="daemonset" ;;
    cronjob|cj|cronjobs)           WKIND="cronjob" ;;
    job|jobs)                      WKIND="job" ;;
    *) die "unsupported workload kind '$WKIND' (deployment|statefulset|daemonset|cronjob|job)" ;;
  esac
fi

if [[ $ALL_NS -eq 0 ]]; then
  if [[ -z "$NS" ]]; then
    NS="$(kubectl config view --minify -o 'jsonpath={..namespace}' 2>/dev/null || true)"
    NS="${NS:-default}"
  fi
  k get namespace "$NS" >/dev/null 2>&1 || die "cannot access namespace '$NS' (missing, or forbidden)"
fi

# ------------------------------------------------------------------ operator
RELOADER_TARGET="$(find_reloader)"
build_operator "$RELOADER_TARGET"
info "reloader target: ${RELOADER_TARGET:-<not found>}"

GLOBAL_AUTO=false
if [[ "$(jq -r '.autoReloadAll // ""' <<<"$OPERATOR_JSON")" == *true* ]]; then GLOBAL_AUTO=true; fi

OP_SELECTOR_VAL="$(jq -r '.namespaceSelector  // ""' <<<"$OPERATOR_JSON")"; OP_SELECTOR_VAL="${OP_SELECTOR_VAL#*=}"
OP_IGNORE_VAL="$(jq -r '.namespacesToIgnore // ""' <<<"$OPERATOR_JSON")"; OP_IGNORE_VAL="${OP_IGNORE_VAL#*=}"

RBAC_SELS_JSON="$(jq -c "$RBAC_SEL_JQ" <<<"$OPERATOR_JSON")"
if [[ -z "$RBAC_SELS_JSON" ]]; then RBAC_SELS_JSON='[]'; fi
RBAC_SEL_JOINED="$(jq -r 'if length == 1 then .[0] else "" end' <<<"$RBAC_SELS_JSON")"
RBAC_NAMES="$(jq -r '([ .rbac[]?.rules[]? | .resourceNames // [] ] | add // []) | unique | join(",")' <<<"$OPERATOR_JSON")"

# --------------------------------------------------------- target namespaces
# OP_NS_LIST is the operator's own namespace scope; it is NOT the run's target
# list (a -n run still needs the operator scope for --show-scope resolution).
declare -a TARGET_NS=()
declare -a OP_NS_LIST=()
declare -a SKIPPED_NS=()

NS_JSON=""
if [[ $ALL_NS -eq 1 || $SHOW_SCOPE -eq 1 ]]; then
  NS_JSON="$(k get namespace -o json 2>/dev/null || true)"
fi

if [[ -n "$OP_SELECTOR_VAL" ]] && { [[ "$OP_SELECTOR_VAL" == *"("* ]] || [[ "$OP_SELECTOR_VAL" == *" in "* ]] || [[ "$OP_SELECTOR_VAL" == *" notin "* ]]; }; then
  warn "operator namespace selector '$OP_SELECTOR_VAL' uses set-based syntax this tool cannot evaluate; auditing all namespaces"
  OP_SELECTOR_VAL=""
fi

if [[ -n "$NS_JSON" ]]; then
  mapfile -t OP_NS_LIST < <(jq -r --arg sel "$OP_SELECTOR_VAL" --arg ign "$OP_IGNORE_VAL" '
    def sel_ok($labels):
      if $sel == "" then true
      else ($sel | split(",") | map(select(length > 0))
            | all(. as $c |
                if ($c | test("!=")) then
                  ($c | split("!=")) as $p | (($labels[$p[0]] // "") != ($p[1] // ""))
                else
                  ($c | split("=")) as $p | (($labels[$p[0]] // "") == ($p[1] // ""))
                end))
      end;
    ($ign | split(",") | map(select(length > 0))) as $ignored
    | (.items // [])[]
    | . as $nsitem
    | select(($ignored | index($nsitem.metadata.name)) == null)
    | select(sel_ok($nsitem.metadata.labels // {}))
    | $nsitem.metadata.name' <<<"$NS_JSON" | sort)
else
  if [[ $ALL_NS -eq 1 ]]; then die "no namespaces returned by the API server"; fi
  if [[ $SHOW_SCOPE -eq 1 ]]; then warn "could not list namespaces; namespace-scope filtering is disabled for this run"; fi
fi

if [[ $ALL_NS -eq 1 ]]; then
  TARGET_NS=("${OP_NS_LIST[@]}")
  [[ ${#TARGET_NS[@]} -gt 0 ]] || die "no namespaces left to audit after applying the operator's scope (selector='${OP_SELECTOR_VAL:-none}' ignore='${OP_IGNORE_VAL:-none}'); audit one explicitly with -n NS"

  mapfile -t SKIPPED_NS < <(comm -13 \
    <(printf '%s\n' "${TARGET_NS[@]:-}" | sed '/^$/d' | sort) \
    <(jq -r '(.items // [])[].metadata.name' <<<"$NS_JSON" | sort))

  if [[ ${#SKIPPED_NS[@]} -gt 0 ]]; then
    SKIPPED_LIST="$(IFS=,; printf '%s' "${SKIPPED_NS[*]}")"
    warn "skipping namespace(s) excluded by the operator's own scope: $SKIPPED_LIST (audit one explicitly with -n NS)"
    NS_SCOPE_NOTE="all namespaces except: $SKIPPED_LIST"
  else
    SKIPPED_LIST=""
    NS_SCOPE_NOTE="all namespaces"
  fi
else
  SKIPPED_LIST=""
  NS_SCOPE_NOTE="namespace ${NS} (operator scope not applied)"
  TARGET_NS=("$NS")
fi

# namespace set used by --show-scope (the operator's scope, not the run's)
if [[ ${#OP_NS_LIST[@]} -gt 0 ]]; then
  NS_SET_JSON="$(printf '%s\n' "${OP_NS_LIST[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')"
else
  NS_SET_JSON="null"
fi

if [[ -n "$WORKLOAD" && $ALL_NS -eq 0 ]]; then
  if ! k get "$WKIND" -n "$NS" "$WNAME" -o name >/dev/null 2>&1; then
    printf '%s: error: workload not found: %s/%s in namespace %s\n' "$PROG" "$WKIND" "$WNAME" "$NS" >&2
    printf 'workloads present in %s:\n' "$NS" >&2
    k get "$KINDS" -n "$NS" -o name 2>/dev/null | sed 's/^/  /' >&2 || true
    exit 2
  fi
fi

# ------------------------------------------------------------ scope resolver
SCOPE_JSON="null"

scope_list() {   # $1 = secrets|configmaps -> JSON {count, shown, truncated}
  local plural="$1" tsv
  local -a args=(get "$plural" -A)
  if [[ -n "$RBAC_SEL_JOINED" ]]; then args+=(-l "$RBAC_SEL_JOINED"); fi
  tsv="$(k "${args[@]}" -o go-template='{{range .items}}{{.metadata.namespace}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{if .metadata.annotations}}{{index .metadata.annotations "reloader.stakater.com/ignore"}}{{end}}{{"\t"}}{{range $k,$v := .metadata.labels}}{{$k}}={{$v}};{{end}}{{"\n"}}{{end}}' 2>/dev/null || true)"
  printf '%s' "$tsv" | jq -R -s \
    --argjson nsset "$NS_SET_JSON" \
    --argjson sels "$RBAC_SELS_JSON" \
    --argjson limit "$SCOPE_LIMIT" '
    def sel_ok($labels):
      if . == "" then true
      else (split(",") | map(gsub("^[ ]+|[ ]+$"; "")) | map(select(length > 0))
            | [ .[] |
                if   test("^!")      then ($labels[.[1:]] // null) == null
                elif test(" notin ") then (split(" notin ")) as $p
                                         | (($p[1] | ltrimstr("(") | rtrimstr(")") | split(","))
                                            | index($labels[$p[0]] // "\u0000")) == null
                elif test(" in ")    then (split(" in ")) as $p
                                         | (($p[1] | ltrimstr("(") | rtrimstr(")") | split(","))
                                            | index($labels[$p[0]] // "\u0000")) != null
                elif test("!=")      then (split("!=")) as $p | (($labels[$p[0]] // "") != $p[1])
                elif test("=")       then (split("="))  as $p | (($labels[$p[0]] // "") == $p[1])
                else ($labels[.] != null)
                end ]
            | all)
      end;
    def rbac_ok($labels):
      if ($sels | length) == 0 then true else any($sels[]; sel_ok($labels)) end;
    split("\n") | map(select(length > 0) | split("\t"))
    | map({ ns: .[0], name: .[1], ignore: (.[2] // ""),
            labels: ((.[3] // "") | split(";") | map(select(length > 0) | split("="))
                     | map({ key: .[0], value: (.[1:] | join("=")) }) | from_entries) })
    | map(. as $o | select(if $nsset == null then true else (($nsset | index($o.ns)) != null) end))
    | map(select(.ignore != "true"))
    | map(select(rbac_ok(.labels)))
    | . as $o
    | { count: ($o | length),
        shown: (($o[0:$limit]) | map(.ns + "/" + .name)),
        truncated: (($o | length) > $limit) }'
}

if [[ $SHOW_SCOPE -eq 1 ]]; then
  SECRETS_SCOPE_JSON="$(scope_list secrets)"
  CONFIGMAPS_SCOPE_JSON="$(scope_list configmaps)"

  if [[ "$(jq 'length' <<<"$RBAC_SELS_JSON")" -gt 1 ]]; then
    SEL_DISPLAY="$(jq -r 'join(" OR ")' <<<"$RBAC_SELS_JSON")"
  else
    SEL_DISPLAY="$RBAC_SEL_JOINED"
  fi

  SCOPE_JSON="$(jq -n \
    --arg sel "$SEL_DISPLAY" \
    --arg names "$RBAC_NAMES" \
    --argjson ns "$NS_SET_JSON" \
    --argjson s "$SECRETS_SCOPE_JSON" \
    --argjson c "$CONFIGMAPS_SCOPE_JSON" '
    { labelSelector: (if $sel == "" then null else $sel end),
      resourceNames: (if $names == "" then null else $names end),
      namespaces: (if $ns == null then [] else $ns end),
      secrets: $s, configmaps: $c }')"
fi

# ---------------------------------------------------------------------- main
REPORTS="$WORK/reports.ndjson"
: > "$REPORTS"
WL_COUNT=0

for ns in "${TARGET_NS[@]}"; do
  info "auditing namespace $ns"
  build_index "$ns"

  if [[ -n "$WORKLOAD" ]]; then
    wljson="$(k get "$WKIND" -n "$ns" "$WNAME" -o json 2>/dev/null || true)"
    # Defensive: some wrappers/proxies return a List for a named get.
    if [[ "$(jq -r '.kind // ""' <<<"$wljson" 2>/dev/null)" == "List" ]]; then
      wljson="$(jq -c '.items[0] // empty' <<<"$wljson")"
    fi
    [[ -z "$wljson" ]] && continue
    obj="$(printf '%s' "$wljson" | jq -c --arg ctx "$CTX" --argjson gauto "$GLOBAL_AUTO" \
            --argjson rbacsels "$RBAC_SELS_JSON" \
            --slurpfile idx "$WORK/idx-$ns.json" -f "$WORK/audit.jq")" \
      || die "analysis failed for $WKIND/$WNAME in $ns"
    printf '%s\n' "$obj" >> "$REPORTS"
    WL_COUNT=$((WL_COUNT + 1))
  else
    all="$(k get "$KINDS" -n "$ns" -o json 2>/dev/null || true)"
    if [[ -z "$all" ]]; then warn "cannot list workloads in namespace $ns (skipped)"; continue; fi
    while IFS= read -r wljson; do
      [[ -z "$wljson" ]] && continue
      obj="$(printf '%s' "$wljson" | jq -c --arg ctx "$CTX" --argjson gauto "$GLOBAL_AUTO" \
              --argjson rbacsels "$RBAC_SELS_JSON" \
              --slurpfile idx "$WORK/idx-$ns.json" -f "$WORK/audit.jq")" \
        || { warn "analysis failed for a workload in $ns (skipped)"; continue; }
      printf '%s\n' "$obj" >> "$REPORTS"
      WL_COUNT=$((WL_COUNT + 1))
    done < <(jq -c '.items[]?' <<<"$all")
  fi
done

[[ $WL_COUNT -gt 0 ]] || die "no workloads found for the given selection"

TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
SKIPPED_JSON="$(printf '%s\n' "${SKIPPED_NS[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')"

if [[ "$OUT" == "json" ]]; then
  jq -s --arg ctx "$CTX" --arg ts "$TS" --arg tool "$PROG $VERSION" \
        --arg kinds "$KINDS" --arg nsscope "$NS_SCOPE_NOTE" \
        --argjson skipped "$SKIPPED_JSON" --argjson op "$OPERATOR_JSON" \
        --argjson scope "$SCOPE_JSON" '
    { meta: { tool: $tool, context: $ctx, generatedAt: $ts,
              kinds: $kinds, namespaceScope: $nsscope, skippedNamespaces: $skipped,
              limitation: "Eligibility is inferred from live workload annotations, pod specs, ConfigMap/Secret annotations, Reloader flags, RBAC and the objects those selectors resolve to. Reloader internal watch state is not observable; confirm reload events from the controller logs." },
      reloaderOperator: $op,
      scope: $scope,
      workloads: . }' "$REPORTS"
else
  printf '\n%s\n' "================================================================================"
  printf '  reloader-audit %s   context=%s   workloads=%s   %s\n' "$VERSION" "$CTX" "$WL_COUNT" "$TS"
  printf '  kinds: %s\n' "$KINDS"
  printf '  namespaces: %s\n' "$NS_SCOPE_NOTE"
  printf '%s\n' "================================================================================"
  while IFS= read -r obj; do
    printf '\n%s\n' "--------------------------------------------------------------------------------"
    printf '%s\n' "$obj" | jq -r -f "$WORK/render.jq"
  done < "$REPORTS"

  render_operator
  render_scope

  NOT_COVERED="$(jq -s '[ .[] | select(any(.coverage[]?; .verdict == "NOT-MONITORED")) ] | length' "$REPORTS")"
  SUSPECT="$(jq -s '[ .[] | select(any(.warnings[]?; .code | startswith("annotation-entry-"))) ] | length' "$REPORTS")"
  OPT_OUT="$(jq -s '[ .[] | select(.flags.autoOptOut) ] | length' "$REPORTS")"
  HIDDEN="$(jq -s '[ .[] | select(any(.coverage[]?; .verdict == "rbac-filtered")) ] | length' "$REPORTS")"

  printf '\n%s\n' "--------------------------------------------------------------------------------"
  printf '  Summary\n'
  printf '    workloads audited                          : %s\n' "$WL_COUNT"
  printf '    workloads with NOT MONITORED references    : %s\n' "$NOT_COVERED"
  printf '    workloads with RBAC-invisible references   : %s\n' "$HIDDEN"
  printf '    workloads with malformed trigger values    : %s\n' "$SUSPECT"
  printf '    workloads explicitly opted out (auto false): %s\n' "$OPT_OUT"
  printf '\n'
  printf '    NOTE: this reports what Reloader is *configured* to watch. Reloader internal\n'
  printf '    watch state is not observable, and cluster-level namespace selectors, RBAC\n'
  printf '    labelSelectors/resourceNames and custom annotation keys can further restrict\n'
  printf '    scope. Confirm real reload events from the controller log, e.g.\n'
  printf '      kubectl -n %s logs deploy/%s | grep -i reload\n' \
    "${RELOADER_TARGET%%/*}" "${RELOADER_TARGET##*/}"
fi

if [[ $STRICT -eq 1 ]]; then
  TOTAL_WARN="$(jq -s '[ .[].warnings[]? | select(.severity == "warn") ] | length' "$REPORTS")"
  if [[ "$TOTAL_WARN" -gt 0 ]]; then
    printf '\n%s: --strict: %s warn-severity finding(s)\n' "$PROG" "$TOTAL_WARN" >&2
    exit 1
  fi
fi
exit 0
