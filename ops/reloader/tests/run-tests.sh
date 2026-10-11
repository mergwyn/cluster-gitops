#!/usr/bin/env bash
# Offline test suite for reloader-audit.sh. No cluster required.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${RELOADER_AUDIT:-$HERE/../reloader-audit.sh}"
WORLD="$HERE/world.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -f "$AUDIT" ]] || { echo "reloader-audit.sh not found at $AUDIT (set RELOADER_AUDIT=...)"; exit 3; }
chmod +x "$HERE/fake-kubectl"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<EOF
#!/usr/bin/env bash
exec "$HERE/fake-kubectl" "\$@"
EOF
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"
export FAKE_WORLD="$WORLD"

# Hard guard: never let this suite touch a real cluster.
if [[ "$(kubectl config current-context 2>/dev/null || true)" != "fake-context" ]]; then
  echo "FATAL: kubectl resolved to $(command -v kubectl) — the shim is not in effect. Aborting before touching a real cluster."
  exit 4
fi
preflight() {
  local fails=0
  pf() {  # pf <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
  }
  pf "named get returns the object, not a List" "Deployment" \
     "$(kubectl get deployment -n default phonebook -o json | jq -r '.kind')"
  pf "named get resolves the workload name" "phonebook" \
     "$(kubectl get deployment -n default phonebook -o json | jq -r '.metadata.name')"
  pf "list get in one namespace" "3" \
     "$(kubectl get deployment,statefulset,daemonset,cronjob,job -n default -o json | jq -r '.items | length')"
  pf "list get cluster-wide" "7" \
     "$(kubectl get deployment,statefulset,daemonset,cronjob,job -A -o json | jq -r '.items | length')"
  pf "label select across namespaces" "reloader-system/reloader-reloader" \
     "$(kubectl get deployment -A -l app.kubernetes.io/name=reloader -o json | jq -r '.items[0] | .metadata.namespace + "/" + .metadata.name')"
  pf "index template emits 3 tab-separated fields" "3" \
     "$(kubectl get configmaps -n default -o go-template=x | head -1 | awk -F'\t' '{print NF}')"
  pf "namespace list" "4" "$(kubectl get namespace -o json | jq -r '.items | length')"
  pf "clusterrolebinding list" "1" "$(kubectl get clusterrolebinding -o json | jq -r '.items | length')"
  printf '\n'
  if [[ $fails -gt 0 ]]; then
    echo "shim preflight failed ($fails) — fix tests/fake-kubectl before trusting results"
    exit 5
  fi
}
preflight

PASS=0; FAIL=0; CODE=0; LAST_LABEL=""

run() {  # run <label> -- <args...>
  local label="$1"; shift; shift
  set +e
  "$AUDIT" "$@" > "$TMP/out" 2> "$TMP/err"
  CODE=$?
  set -e
  LAST_LABEL="$label"
}

check_contains() {
  if grep -qF -- "$1" "$TMP/out"; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL [$LAST_LABEL] missing: $1"; fi
}
check_absent() {
  if grep -qF -- "$1" "$TMP/out"; then FAIL=$((FAIL+1)); echo "FAIL [$LAST_LABEL] unexpected: $1";
  else PASS=$((PASS+1)); fi
}
check_code() {
  if [[ "$CODE" == "$1" ]]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL [$LAST_LABEL] exit code $CODE, wanted $1"; sed 's/^/    /' "$TMP/err"; fi
}
check_jq() {  # check_jq <filter>
  if jq -e "$1" "$TMP/out" >/dev/null 2>&1; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); echo "FAIL [$LAST_LABEL] jq assertion failed: $1"; fi
}

# --- 1. phonebook: auto-reload on, every reference covered -------------------
run "phonebook" -- -n default -w deployment/phonebook
check_code 0
check_contains 'auto (all referenced Secrets + ConfigMaps) : ENABLED'
check_contains '-> effective auto for Secrets              : YES'
check_contains 'projected keys: jwt'
check_contains 'projected keys: app.conf'
check_absent   '   <== NOT MONITORED'

# --- 2. velero: "<-" block-scalar artefact is flagged, not silently accepted --
run "velero" -- -n velero -w deployment/velero
check_code 0
check_contains 'suspicious'
check_contains 'leaked YAML block-scalar indicator'
check_contains 'suggested clean value: minio-s3-conf,idrivee2-s3-conf'
check_contains 'SECRET    minio-s3-conf'
check_contains 'SECRET    idrivee2-s3-conf'
check_contains 'SECRET    minio-s3-conf   <== NOT MONITORED'
check_contains 'SECRET    idrivee2-s3-conf   covered: explicit annotation'
check_contains 'CONFIGMAP velero-backup-repository-config   covered: explicit annotation'

# --- 3. traefik-style literal "auto" is not treated as a resource name -------
run "traefik" -- -n network -w deployment/traefik
check_code 0
check_contains 'auto-token'
check_contains 'literal "auto" is not a resource name'
check_contains 'NOT MONITORED'

# --- 4. search mode: match annotation decides coverage ----------------------
run "search" -- -n default -w deployment/searchdemo
check_code 0
check_contains 'search / match mode                        : ENABLED'
check_contains 'covered: search + match'
check_contains 'CONFIGMAP unmatched-config   <== NOT MONITORED'

# --- 5. annotations on the pod template are surfaced with provenance --------
run "podtmpl" -- -n default -w deployment/legacy-podtmpl
check_code 0
check_contains '[podTemplate]'
check_contains 'set on the pod template only'

# --- 6. CronJob uses .spec.jobTemplate.spec.template ------------------------
run "cronjob" -- -n velero -w cronjob/velero-backup
check_code 0
check_contains 'pod template : .spec.jobTemplate.spec.template'
check_contains 'velero-backup-repository-config'

# --- 7. missing workload -> exit 2 + hints ----------------------------------
run "missing" -- -n default -w deployment/does-not-exist
check_code 2
if grep -qF 'workload not found' "$TMP/err"; then PASS=$((PASS+1));
else FAIL=$((FAIL+1)); echo "FAIL [missing] no error text on stderr"; fi

# --- 8. cluster-wide JSON is valid and complete -----------------------------
# default: phonebook, legacy-podtmpl, searchdemo
# network: traefik
# velero:  velero (Deployment), velero-backup (CronJob)
# reloader-system: reloader-reloader (Deployment)   -> 7 total
run "json" -- -A -o json
check_code 0
check_jq '(.workloads | length) == 7'
check_jq '.reloaderOperator.namespace == "reloader-system"'
check_jq '[.workloads[] | select(any(.coverage[]?; .verdict == "NOT-MONITORED"))] | length == 3'
check_jq '[.workloads[] | select(.name == "velero")][0].coverage[] | select(.name == "minio-s3-conf") | .verdict == "NOT-MONITORED"'

# --- 9. --strict fails the run when warn findings exist ---------------------
run "strict" -- -n network -w deployment/traefik --strict
check_code 1

# --- 10. operator scoping is reported ---------------------------------------
run "scoping" -- -n default -w deployment/phonebook
check_contains 'namespaceSelector  : --namespace-selector=environment=production'
check_contains 'labelSelector='
check_contains 'auto-reload-all    : --auto-reload-all=false'

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
echo "ALL TESTS PASSED"
