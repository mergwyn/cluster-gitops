#!/usr/bin/env bash
# build-doctor-kubeconfig.sh
#
# Run this once (from a machine with kubectl access to k3s-prod, e.g. mike)
# after applying rbac/helmfile-doctor-rbac.yaml. Produces a standalone
# kubeconfig for the helmfile-doctor ServiceAccount, then uploads it as a
# GitHub Actions secret.
#
# Requires: kubectl (pointed at k3s-prod), gh (authenticated), base64.
#
# Re-run this if you ever rotate the token (delete + recreate the Secret
# in rbac/helmfile-doctor-rbac.yaml first, then re-run this script).

set -euo pipefail

NAMESPACE="kube-system"
SA_NAME="helmfile-doctor"
TOKEN_SECRET="helmfile-doctor-token"
GH_SECRET_NAME="HELMFILE_DOCTOR_KUBECONFIG"
OUT_FILE="doctor-kubeconfig.yaml"
REPO="mergwyn/cluster-gitops"

echo "Reading cluster CA and server URL from current kubeconfig context..."
CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')

echo "Reading ServiceAccount token from ${NAMESPACE}/${TOKEN_SECRET}..."
TOKEN=$(kubectl get secret "${TOKEN_SECRET}" -n "${NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: token was empty. Has the Secret been reconciled yet? (can take a few seconds after apply)" >&2
  exit 1
fi

cat > "${OUT_FILE}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k3s-prod-doctor
    cluster:
      certificate-authority-data: ${CA}
      server: ${SERVER}
contexts:
  - name: helmfile-doctor
    context:
      cluster: k3s-prod-doctor
      user: helmfile-doctor
current-context: helmfile-doctor
users:
  - name: helmfile-doctor
    user:
      token: ${TOKEN}
EOF

echo "Wrote ${OUT_FILE}"

read -r -p "Upload as GitHub secret '${GH_SECRET_NAME}' on ${REPO} now? [y/N] " CONFIRM
if [[ "${CONFIRM}" =~ ^[Yy]$ ]]; then
  gh secret set "${GH_SECRET_NAME}" --repo "${REPO}" < "${OUT_FILE}"
  echo "Uploaded. Removing local copy (it contains a live token)..."
  rm -f "${OUT_FILE}"
else
  echo "Skipped upload. ${OUT_FILE} contains a live token — store it securely and delete it once uploaded."
fi
