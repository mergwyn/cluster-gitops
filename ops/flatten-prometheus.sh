#!/usr/bin/env bash
# flatten-prometheus.sh

set -o errexit
set -o pipefail
set -o nounset

NAMESPACE="monitoring"
APP_NAME="kube-prometheus-stack"
SELECTOR="app.kubernetes.io/instance=$APP_NAME"
ARGOCD_APP="kube-prometheus-stack"
ARGOCD_PROJECT="default"
WINDOW_SCHEDULE='* * * * *'
WINDOW_DURATION='1h'
BACKUP_NAME="flatten-prom-$(date +%Y%m%d-%H%M%S)"
RESTORE_NAME="restore-$BACKUP_NAME"

echo "=== Starting Prometheus Snapshot Flattening Cycle ==="

# 1. Freeze ArgoCD from interfering
echo "--- Freezing ArgoCD App Sync via Deny Window ---"
argocd proj windows add "$ARGOCD_PROJECT" \
  --kind deny \
  --schedule "$WINDOW_SCHEDULE" \
  --duration "$WINDOW_DURATION" \
  --applications "$ARGOCD_APP"

# Set up automatic cleanup on script exit or crash
on_exit() {
  echo "--- Performing Safety Cleanup Action Items ---"
  argocd proj windows remove "$ARGOCD_PROJECT" \
    --kind deny \
    --schedule "$WINDOW_SCHEDULE" \
    --duration "$WINDOW_DURATION" \
    --applications "$ARGOCD_APP" || true
    
  echo "--- Rescaling Prometheus Stack components back online ---"
  kubectl scale deployment -l "app.kubernetes.io/component=prometheus-operator" -n "$NAMESPACE" --replicas=1 || true
  kubectl scale statefulset prometheus-kube-prometheus-stack-prometheus -n "$NAMESPACE" --replicas=1 || true
}
trap on_exit EXIT

# 2. Scale the Operator down first
echo "--- Scaling down Prometheus Operator ---"
kubectl scale deployment -l "app.kubernetes.io/component=prometheus-operator" -n "$NAMESPACE" --replicas=0
kubectl wait --for=delete pod -l "app.kubernetes.io/component=prometheus-operator" -n "$NAMESPACE" --timeout=60s || true

# 3. Kill the database pods
echo "--- Scaling down Prometheus Storage Engine instances ---"
kubectl scale statefulset prometheus-kube-prometheus-stack-prometheus -n "$NAMESPACE" --replicas=0
kubectl wait --for=delete pod -l "app.kubernetes.io/name=prometheus" -n "$NAMESPACE" --timeout=60s || true

# 4. Take a flat block snapshot via Velero
echo "--- Creating flat Velero backup image: $BACKUP_NAME ---"
velero backup create "$BACKUP_NAME" \
  --include-namespaces "$NAMESPACE" \
  --selector "app.kubernetes.io/name=prometheus" \
  --wait

# 5. Delete the bloated Longhorn volumes
echo "--- Nucking the current bloated 60GB+ storage objects ---"
PV_NAMES=$(kubectl get pvc -l "app.kubernetes.io/name=prometheus" -n "$NAMESPACE" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)

kubectl delete pvc -l "app.kubernetes.io/name=prometheus" -n "$NAMESPACE" --ignore-not-found

if [[ -n "$PV_NAMES" ]]; then
    for pv in $PV_NAMES; do
        kubectl wait pv "$pv" --for=jsonpath='{.status.phase}'=Released --timeout=30s 2>/dev/null || true
        kubectl delete pv "$pv" --ignore-not-found
    done
fi

# 6. Restore the clean, flattened baseline blocks
echo "--- Initiating flat restore cycle: $RESTORE_NAME ---"
velero restore create "$RESTORE_NAME" \
  --from-backup "$BACKUP_NAME" \
  --existing-resource-policy update \
  --wait

# 7. Final Verification Check
echo "--- Verifying the new storage bindings ---"
kubectl get pvc -n "$NAMESPACE"

echo "=== Flatten Cycle Completed Successfully ==="

