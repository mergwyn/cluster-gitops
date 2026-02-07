#!/usr/bin/env bash
set -euo pipefail

RAW_KUBECONFIG="$1"
CLUSTER_NAME="$2"
DEFAULT_NAMESPACE="${3:-argocd}"

if [[ ! -f "$RAW_KUBECONFIG" ]]; then
  echo "ERROR: kubeconfig not found: $RAW_KUBECONFIG"
  exit 1
fi

echo ">>> Normalising kubeconfig for cluster: ${CLUSTER_NAME}"

kubectl config rename-cluster default "${CLUSTER_NAME}" \
  --kubeconfig="${RAW_KUBECONFIG}"

kubectl config rename-user default "${CLUSTER_NAME}-admin" \
  --kubeconfig="${RAW_KUBECONFIG}"

kubectl config rename-context default "${CLUSTER_NAME}-admin" \
  --kubeconfig="${RAW_KUBECONFIG}"

kubectl config set-context "${CLUSTER_NAME}-admin" \
  --cluster="${CLUSTER_NAME}" \
  --user="${CLUSTER_NAME}-admin" \
  --namespace="${DEFAULT_NAMESPACE}" \
  --kubeconfig="${RAW_KUBECONFIG}"

kubectl config use-context "${CLUSTER_NAME}-admin" \
  --kubeconfig="${RAW_KUBECONFIG}"

# Guardrail: fail if any defaults remain
if kubectl config get-contexts --kubeconfig="${RAW_KUBECONFIG}" | grep -q '\bdefault\b'; then
  echo "ERROR: default context still present"
  exit 1
fi

echo ">>> kubeconfig hygiene complete"
