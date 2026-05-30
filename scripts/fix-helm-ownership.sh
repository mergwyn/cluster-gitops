#!/usr/bin/env bash
# Patch Helm ownership annotations onto resources that ArgoCD owns but Helm doesn't

NAMESPACE="${1:-argocd}"

# Extend this list as new kinds are discovered
EXTRA_KINDS=(
  externalsecret
  secret
  # clusterrole
  # clusterrolebinding
  # serviceaccount
)

EXTRA="${EXTRA_KINDS[*]}"
EXTRA="${EXTRA// /,}"

kubectl get "all,$EXTRA" -n "$NAMESPACE" -o json | \
  jq -r '
    .items[] |
    select(
      .metadata.annotations["argocd.argoproj.io/tracking-id"] != null and
      .metadata.annotations["meta.helm.sh/release-name"] == null and
      .metadata.labels["app.kubernetes.io/instance"] != null
    ) |
    "\(.kind)/\(.metadata.name)/\(.metadata.namespace)/\(.metadata.labels["app.kubernetes.io/instance"])"
  ' | while IFS=/ read -r kind name namespace release; do
    echo "Patching $kind/$name in $namespace with release=$release..."
    kubectl annotate "$kind" "$name" -n "$namespace" \
      meta.helm.sh/release-name="$release" \
      meta.helm.sh/release-namespace="$namespace" \
      --overwrite
    kubectl label "$kind" "$name" -n "$namespace" \
      app.kubernetes.io/managed-by=Helm \
      --overwrite
  done

