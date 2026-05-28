* Upgrading CRDs

This extracts the version from your helmfile and feeds it into the CRD apply
```
# This one-liner grabs the version from your helmfile and applies the CRDs
helm show crds oci://ghcr.io/traefik/helm/traefik --version $(grep 'version:' helmfile.yaml | awk '{print $2}') | kubectl apply --server-side --force-conflicts -f -
```
If you need to install the gateway apis:
```
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
```
