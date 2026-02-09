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

# Extract current cluster/server and certificate-authority
SERVER=$(kubectl config view --kubeconfig="$RAW_KUBECONFIG" -o jsonpath='{.clusters[0].cluster.server}')
CA_FILE=$(mktemp)
kubectl config view --kubeconfig="$RAW_KUBECONFIG" --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 --decode > "$CA_FILE"

# Extract current user cert/key
USER_CERT=$(mktemp)
USER_KEY=$(mktemp)
kubectl config view --kubeconfig="$RAW_KUBECONFIG" --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 --decode > "$USER_CERT"
kubectl config view --kubeconfig="$RAW_KUBECONFIG" --raw -o jsonpath='{.users[0].user.client-key-data}' \
  | base64 --decode > "$USER_KEY"

# Create new cluster entry
kubectl config set-cluster "$CLUSTER_NAME" \
  --server="$SERVER" \
  --certificate-authority="$CA_FILE" \
  --embed-certs=true \
  --kubeconfig="$RAW_KUBECONFIG"

# Create new user entry
kubectl config set-credentials "${CLUSTER_NAME}-admin" \
  --client-certificate="$USER_CERT" \
  --client-key="$USER_KEY" \
  --embed-certs=true \
  --kubeconfig="$RAW_KUBECONFIG"

# Create new context
kubectl config set-context "${CLUSTER_NAME}-admin" \
  --cluster="$CLUSTER_NAME" \
  --user="${CLUSTER_NAME}-admin" \
  --namespace="$DEFAULT_NAMESPACE" \
  --kubeconfig="$RAW_KUBECONFIG"

# Switch to the new context
kubectl config use-context "${CLUSTER_NAME}-admin" --kubeconfig="$RAW_KUBECONFIG"

# Clean up temp files
rm -f "$CA_FILE" "$USER_CERT" "$USER_KEY"

# Remove old default entries
kubectl config unset clusters.default --kubeconfig="$RAW_KUBECONFIG" || true
kubectl config unset users.default --kubeconfig="$RAW_KUBECONFIG" || true
kubectl config unset contexts.default --kubeconfig="$RAW_KUBECONFIG" || true

# Guardrail: fail if any defaults remain
if kubectl config get-contexts --kubeconfig="$RAW_KUBECONFIG" | grep -q '\bdefault\b'; then
  echo "ERROR: default context still present"
  exit 1
fi

echo ">>> kubeconfig hygiene complete"
