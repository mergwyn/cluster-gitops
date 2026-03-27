* Upgrading CRDs

This extracts the version from your helmfile and feeds it into the CRD apply
```
# This one-liner grabs the version from your helmfile and applies the CRDs
helm show crds oci://ghcr.io/traefik/helm/traefik --version $(grep 'version:' helmfile.yaml | awk '{print $2}') | kubectl apply --server-side --force-conflicts -f -
```
