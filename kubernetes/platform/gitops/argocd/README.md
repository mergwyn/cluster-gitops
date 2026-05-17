# ArgoCD

ArgoCD is deployed via helmfile as part of the `platform/gitops` wave (wave 1).

## Directory Structure

```
platform/gitops/argocd/
├── app.yaml                  # ApplicationSet discovery file (wave: 1, namespace: argocd)
├── helmfile.yaml             # Helmfile deploying argocd-secret, argocd, and argocd-externalsecret
├── values.yaml               # ArgoCD Helm values (repoServer, configs, ingress, resources)
├── values-rules.yaml         # Prometheus alerting rules (separate file to avoid bootstrap CRD dependency)
├── argocd-secret-sops.yaml   # SOPS/age-encrypted ArgoCD admin secret
├── externalsecret.yaml       # ExternalSecret pulling argocd initial-admin-secret from Bitwarden via ESO
└── README.md                 # This file
```

## Releases

The helmfile deploys three releases in order:

|Release                |Chart           |Purpose                                                         |
|-----------------------|----------------|----------------------------------------------------------------|
|`argocd-secret`        |bedag/raw       |ArgoCD admin password and server secret key, decrypted from SOPS|
|`argocd`               |argoproj/argo-cd|ArgoCD itself                                                   |
|`argocd-externalsecret`|bedag/raw       |ESO ExternalSecret for the initial admin secret from Bitwarden  |

## Secrets

Two secrets mechanisms are in use, reflecting bootstrap ordering constraints:

**SOPS/age** (`argocd-secret-sops.yaml`) is used for the core ArgoCD secret (`argocd-secret`) because
ESO is not available at wave 1. The age private key must exist in the cluster before ArgoCD is
deployed:

```bash
kubectl create secret generic argocd-age-secret-keys \
  --from-file=keys.txt=/path/to/age.key \
  -n argocd
```

**ESO** (`externalsecret.yaml`) is used for the initial admin secret, sourced from Bitwarden via
the `bitwarden` ClusterSecretStore. This reconciles after ESO is up.

## CMP Plugin

ArgoCD uses the `travisghansen/argo-cd-helmfile` image as a sidecar Config Management Plugin (CMP),
enabling helmfile-based ApplicationSets across the cluster.

The plugin is configured in `values.yaml` under `repoServer.extraContainers`.

### Known Limitation / Future Work

The `travisghansen/argo-cd-helmfile` plugin has not been updated for some time and ships with older
helmfile and helm versions. The planned replacement is a **custom sidecar image** built and owned
in this repo, which would:

- Bundle pinned versions of helmfile, helm, sops, age, and helm-secrets
- Be built via a GitHub Action and pushed to GHCR
- Allow Renovate to track all binary versions via Dockerfile `ARG` lines
- Require no changes to the ApplicationSet or any helmfiles
- Replace only the `image:` reference in `repoServer.extraContainers`

This is deferred until the current plugin causes a compatibility issue. See the conversation
history for the full design.


### Others
add metrics
https://github.com/argoproj/argo-cd/issues/14885
https://github.com/argoproj/argo-cd/issues/11411


## Ingress

ArgoCD is exposed via a Traefik `IngressRoute` at `https://argocd.theclarkhome.com`. gRPC
(used by the CLI) is handled by a separate route matching on `Content-Type: application/grpc`,
forwarded with scheme `h2c`.

TLS termination is handled by Traefik. The server runs in insecure mode (`server.insecure: true`)
since TLS is terminated at the ingress layer.

## Prometheus Alerting

Alerting rules are in `values-rules.yaml` rather than `values.yaml` to avoid a dependency on the
Prometheus Operator CRDs during bootstrap. They are applied after the CRDs are available.

Alerts defined:

|Alert                   |Condition                   |Severity|
|------------------------|----------------------------|--------|
|`ArgocdServiceNotSynced`|Any app not synced for 15m  |warning |
|`ArgocdServiceUnhealthy`|Any app not healthy for 15m |warning |
|`ArgoAppMissing`        |No app data reported for 15m|critical|
|`ArgoAppNotSynced`      |Any app not synced for 12h  |warning |

## Resource Requests

Resources are tuned for the home lab cluster. Limits are set without CPU limits (commented out)
to avoid throttling on bursty workloads.

|Component     |Memory Request|Memory Limit|
|--------------|--------------|------------|
|controller    |1844Mi        |2048Mi      |
|repo-server   |308Mi         |1400M       |
|server        |236Mi         |1416M       |
|applicationSet|105M          |1183M       |
|dex           |105M          |750M        |
|notifications |105M          |750M        |
|redis         |105M          |174M        |
