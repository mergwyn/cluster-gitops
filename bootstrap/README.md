# Bootstrap

## Introduction
This drectory contains the code necessary to boostrap and also contains charts
in the initial progessive sync of the cluster

## Cluster bootstrap

There is a makefile that orchestrates the iniitlaisation of the cluster. To
boostrap an empty cluster run `make install`.  This will install the bare
minimum secrets, keys and apps to get argocd running, and then will create and
application set to complete the installation

The make targets available are:
```
install: secrets crds apps appset
all: cluster install
check: lint
clean: clean-cluster
crds:
secrets: sops-age-key
sops-age-key:
apps: secrets crds sync
sync apply lint:
appset:
```


In addition, it is also possible to create a dev cluster using k3d for testing
using the targets:
```
cluster: clean-cluster
clean-cluster:
```

# Bootstrap

This directory is responsible for **cluster bring-up**, not ongoing application
reconciliation.

Everything under `bootstrap/` exists to take a node (or set of nodes) from
“machine with Kubernetes bits installed” to “ready for GitOps”.

If you are looking for application or platform workloads, you are in the
wrong place.

---

## What belongs here

Bootstrap owns components that are:

- Required **before** ArgoCD can function
- Needed to establish a **stable Kubernetes API endpoint**
- Environment-specific by necessity
- Installed **imperatively** (Helmfile / scripts)

Examples:

- kube-vip (API virtual IP)
- MetalLB (L2/L3 service IPs)
- Cilium (cluster networking)
- CRDs required by the above

---

## What does NOT belong here

The following must *never* live under `bootstrap/`:

- Applications
- Operators managed by ArgoCD
- AppSets
- Long-lived runtime configuration
- Anything reconciled continuously

Those live in the GitOps layer.

---

## The Contract

Bootstrap and GitOps have a **one-way dependency**:

> Bootstrap may depend on Git state  
> GitOps must never depend on bootstrap

Practically, this means:

- Bootstrap runs first
- Bootstrap creates the conditions GitOps assumes
- GitOps does not reference bootstrap environments or values
- No values are shared between the two layers

---

## Environments

Helmfile environments under `bootstrap/environments/` represent
**cluster creation inputs**, not deployment environments.

They may contain:

- Virtual IPs
- Network interfaces
- Node selectors
- Cloud / lab-specific settings

They must not be reused outside bootstrap.

---

## Typical Flow

1. Nodes are provisioned
2. k3s is installed and configured
3. `bootstrap/` is applied
4. ArgoCD is installed
5. GitOps takes over

Bootstrap should be safe to re-run, but is not intended for continuous
reconciliation.

---

## Philosophy

Bootstrap answers the question:

> “What must exist before GitOps can even start?”

If the answer is “nothing”, it does not belong here.



Helmfile secrets: are decrypted client-side and do not imply a Kubernetes dependency.
ExternalSecrets are runtime controllers and belong to platform bootstrap.
