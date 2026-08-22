#!/usr/bin/env bash
# restore-tautulli.sh
# Usage: bash restore-tautulli.sh
# Interactive script to cleanup Velero artifacts and restore Tautulli into media using an existing backup.

set -euo pipefail

# Config - change if needed
NAMESPACE="media"
PVC_NAME="tautulli"
APP_LABEL="app.kubernetes.io/instance=tautulli"
VELERO_NS="velero"
DEFAULT_BACKUP="migration-tautulli-20260605-165408"   # suggested completed backup
TMP_DIR="/tmp/velero-tautulli-$(date +%s)"

mkdir -p "$TMP_DIR"
echo "Working directory: $TMP_DIR"

# Helpers
confirm() {
  read -rp "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

run_and_show() {
  echo "+ $*"
  "$@"
}

check_prereqs() {
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl required"; exit 1; }
  command -v velero >/dev/null 2>&1 || { echo "velero CLI required"; exit 1; }
}

# 1) choose backup
choose_backup() {
  echo
  echo "Velero backups (recent):"
  velero backup get --selector "app.kubernetes.io/instance=tautulli" || velero backup get
  echo
  read -rp "Backup to use (default: $DEFAULT_BACKUP): " BACKUP
  BACKUP=${BACKUP:-$DEFAULT_BACKUP}
  echo "Selected backup: $BACKUP"
}

# 2) find and back up any velero ConfigMaps referencing the PVC or recent restore UIDs
backup_candidate_configmaps() {
  echo
  echo "Searching Velero configmaps for candidates (names/labels containing 'tautulli' or 'media' or 'pvc-namespace-name')..."
  kubectl -n "$VELERO_NS" get configmap -o custom-columns=NAME:.metadata.name,LAB:.metadata.labels --no-headers \
    | egrep -i 'tautulli|media.tautulli|pvc-namespace-name|restore-uid' || true

  echo
  echo "Backing up any configmaps with label velero.io/pvc-namespace-name=media.tautulli (if present) to $TMP_DIR..."
  cms=$(kubectl -n "$VELERO_NS" get configmap -l "velero.io/pvc-namespace-name=$NAMESPACE.$PVC_NAME" -o name 2>/dev/null || true)
  if [[ -n "$cms" ]]; then
    for cm in $cms; do
      name=${cm#configmap/}
      kubectl -n "$VELERO_NS" get configmap "$name" -o yaml > "$TMP_DIR/${name}.yaml"
      echo "Saved $TMP_DIR/${name}.yaml"
    done
  else
    echo "No configmaps found with velero.io/pvc-namespace-name=$NAMESPACE.$PVC_NAME"
  fi

  # also back up any configmaps that have the PVC name anywhere in label set
  echo
  echo "Backing up configmaps whose name or labels mention 'tautulli'..."
  for cm in $(kubectl -n "$VELERO_NS" get configmap -o name 2>/dev/null | grep -i tautulli || true); do
    name=${cm#configmap/}
    kubectl -n "$VELERO_NS" get configmap "$name" -o yaml > "$TMP_DIR/${name}.yaml"
    echo "Saved $TMP_DIR/${name}.yaml"
  done
}

# 3) list in-progress/restores related to tautulli
list_restores() {
  echo
  echo "Velero restores (filtered for tautulli selector if present):"
  velero restore get || true
}

# 4) delete stuck restores (interactive)
delete_stuck_restore() {
  read -rp "Do you want to delete any in-progress restore with name shown above? (y will prompt for name) [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    read -rp "Restore name to delete: " RNAME
    echo "Backing up restore $RNAME to $TMP_DIR/${RNAME}.yaml"
    kubectl -n "$VELERO_NS" get restore "$RNAME" -o yaml > "$TMP_DIR/${RNAME}.yaml" || true
    run_and_show velero restore delete "$RNAME"
    echo "Deleted restore $RNAME"
  fi
}

# 5) delete any existing tautulli PVC (so restore will recreate clean)
delete_existing_pvc() {
  echo
  echo "Current PVCs matching selector:"
  kubectl -n "$NAMESPACE" get pvc -l "$APP_LABEL" -o wide || true
  if confirm "Delete any existing PVC named $PVC_NAME in $NAMESPACE so Velero can recreate it?"; then
    run_and_show kubectl -n "$NAMESPACE" delete pvc "$PVC_NAME" --ignore-not-found
  else
    echo "Skipping PVC deletion. Note: if PVC exists the restore may not recreate it."
  fi
}

# 6) kick off restore
create_restore() {
  echo
  echo "Creating Velero restore (selector $APP_LABEL) from backup $BACKUP..."
  NEW_RESTORE="retry-${BACKUP}-tautulli-$(date +%s)"
  echo "Restore name: $NEW_RESTORE"
  run_and_show velero restore create "$NEW_RESTORE" \
    --from-backup "$BACKUP" \
    --include-namespaces "$NAMESPACE" \
    --selector "$APP_LABEL" \
    --existing-resource-policy update
  echo "Restore request sent. Not waiting — monitoring loop will follow."
}

# 7) monitor: wait for PVC to appear, then patch/remove selector (if present), then create consumer pod to force binding
monitor_and_fix_pvc() {
  echo
  echo "Monitoring for PVC creation (will wait up to 600s)..."
  timeout=600
  elapsed=0
  sleep_interval=4
  pvc_created=""
  while [ $elapsed -lt $timeout ]; do
    if kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" >/dev/null 2>&1; then
      pvc_created=1
      echo "PVC $PVC_NAME detected."
      break
    fi
    sleep $sleep_interval
    elapsed=$((elapsed+sleep_interval))
  done

  if [[ -z "$pvc_created" ]]; then
    echo "PVC did not appear within ${timeout}s. Tailing Velero logs for clues..."
    kubectl -n "$VELERO_NS" logs deploy/velero -c velero --tail=200
    return 2
  fi

  echo "Inspecting PVC YAML and events..."
  kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" -o yaml > "$TMP_DIR/pvc-${PVC_NAME}.yaml"
  kubectl -n "$NAMESPACE" describe pvc "$PVC_NAME" | tee "$TMP_DIR/pvc-${PVC_NAME}.describe"

  # If selector exists, remove it
  has_selector=$(kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" -o jsonpath='{.spec.selector}' 2>/dev/null || true)
  if [[ -n "$has_selector" && "$has_selector" != "null" ]]; then
    echo "PVC has spec.selector (likely from Velero). Will remove it."
    if confirm "Patch to remove /spec/selector from pvc/$PVC_NAME?"; then
      run_and_show kubectl -n "$NAMESPACE" patch pvc "$PVC_NAME" --type=json -p='[{"op":"remove","path":"/spec/selector"}]' || true
      echo "Patched to remove selector. Re-describing pvc..."
      kubectl -n "$NAMESPACE" describe pvc "$PVC_NAME" | tee -a "$TMP_DIR/pvc-${PVC_NAME}.describe"
    else
      echo "Skipped selector removal; provisioner likely will fail."
    fi
  else
    echo "No selector present on PVC."
  fi

  # If PVC is Pending with WaitForFirstConsumer, create consumer pod to trigger binding
  phase=$(kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" -o jsonpath='{.status.phase}' || echo "")
  if [[ "$phase" != "Bound" ]]; then
    echo "PVC phase is '$phase'. Will create a temporary consumer pod to trigger provisioning."
    run_and_show kubectl -n "$NAMESPACE" apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pvc-consumer
  namespace: media
spec:
  restartPolicy: Never
  containers:
  - name: sleep
    image: busybox
    command: ["sh","-c","sleep 1d"]
    volumeMounts:
    - mountPath: /mnt/data
      name: data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: tautulli
EOF
    echo "Consumer pod created (pvc-consumer). Waiting for PVC to bind (up to 300s)..."
    kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" -w --timeout=300s || true
  else
    echo "PVC already Bound."
  fi

  # final checks
  echo "Final PVC describe:"
  kubectl -n "$NAMESPACE" describe pvc "$PVC_NAME" | tee -a "$TMP_DIR/pvc-${PVC_NAME}.describe"
  PV_NAME=$(kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" -o jsonpath='{.spec.volumeName}' || echo "")
  echo "PV chosen: ${PV_NAME:-<none>}"
  if [[ -n "$PV_NAME" ]]; then
    kubectl get pv "$PV_NAME" -o yaml > "$TMP_DIR/pv-${PV_NAME}.yaml"
    echo "Saved PV YAML to $TMP_DIR/pv-${PV_NAME}.yaml"
  fi
}

# 8) inspect files on consumer
inspect_files() {
  echo
  echo "If PVC is Bound and consumer pod exists, list some files for quick check."
  if kubectl -n "$NAMESPACE" get pod pvc-consumer >/dev/null 2>&1; then
    echo "Listing /mnt/data on pvc-consumer:"
    kubectl -n "$NAMESPACE" exec -it pvc-consumer -- sh -c "ls -la /mnt/data || true; du -sh /mnt/data || true; find /mnt/data -maxdepth 4 -type f -name '*.db' -ls || true"
  else
    echo "No pvc-consumer pod found; you can exec into your app pod after you scale it up."
  fi
}

# 9) cleanup consumer
cleanup_consumer() {
  if kubectl -n "$NAMESPACE" get pod pvc-consumer >/dev/null 2>&1; then
    if confirm "Delete the temporary consumer pod pvc-consumer?"; then
      run_and_show kubectl -n "$NAMESPACE" delete pod pvc-consumer --ignore-not-found
    fi
  fi
}

# Main
check_prereqs
choose_backup
backup_candidate_configmaps
list_restores
delete_stuck_restore
delete_existing_pvc
create_restore
monitor_and_fix_pvc
inspect_files

echo
echo "Script finished. Saved diagnostics to $TMP_DIR. If PVC still not Bound or data missing, paste $TMP_DIR/pvc-${PVC_NAME}.describe and velero restore describe output and I'll help next."

