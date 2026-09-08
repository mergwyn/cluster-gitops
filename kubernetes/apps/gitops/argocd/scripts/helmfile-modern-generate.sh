#!/usr/bin/env bash
set -e
[[ "${DEBUG}" == "1" ]] && set -x

export SOPS_AGE_KEY_FILE=/sops/age/keys.txt

# Strip ARGOCD_ENV_ prefix so helmfile.yaml's `env "HELMFILE_NAMESPACE"`
# style lookups (which expect unprefixed names) actually resolve.
while IFS='=' read -r -d '' n v; do
  if [[ "${n}" == ARGOCD_ENV_* ]]; then
    export "${n#ARGOCD_ENV_}"="${v}"
  fi
done < <(env -0)

# Sanitize KUBE_VERSION - k3s reports e.g. "1.30.4+k3s1",
# which breaks Helm's semver parsing if passed through raw.
KUBE_VERSION=$(echo "${KUBE_VERSION}" | sed 's/[^0-9.]*//g')

# Isolate Helm's cache/config per-app to avoid concurrent
# repo-server generate calls racing on shared state.
export HELM_HOME="/tmp/__helmfile-modern__/apps/${ARGOCD_APP_NAME}"
mkdir -p "${HELM_HOME}"
export HOME="${HELM_HOME}"

# Build --api-versions flags from KUBE_API_VERSIONS (CSV),
# forwarded to Helm via helmfile's --args passthrough.
INTERNAL_HELM_API_VERSIONS=""
if [[ -n "${KUBE_API_VERSIONS}" ]]; then
  for v in ${KUBE_API_VERSIONS//,/ }; do
    INTERNAL_HELM_API_VERSIONS="${INTERNAL_HELM_API_VERSIONS} --api-versions=${v}"
  done
fi

INTERNAL_KUBE_VERSION=""
if [[ -n "${KUBE_VERSION}" ]]; then
  INTERNAL_KUBE_VERSION="--kube-version=${KUBE_VERSION}"
fi

helmfile --namespace "${HELMFILE_NAMESPACE}" \
         --environment "${HELMFILE_ENVIRONMENT}" \
         --allow-no-matching-release \
         template \
         --skip-deps \
         --args "${INTERNAL_KUBE_VERSION} ${INTERNAL_HELM_API_VERSIONS}" \
         ${HELMFILE_TEMPLATE_OPTIONS}
