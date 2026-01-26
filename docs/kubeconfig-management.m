# Kubeconfig Management

This document defines how kubeconfigs are created, stored, validated, and consumed across environments.

The goal is to eliminate ambiguity, prevent cross-cluster mistakes, and make kubeconfig handling deterministic and boring.

---

## Principles

- **One kubeconfig per cluster**
  - Each Kubernetes cluster has its own standalone kubeconfig file.
  - These files are treated as immutable inputs once validated.

- **No `default` cluster / user / context allowed**
  - `default` entries are explicitly forbidden.
  - All names must be meaningful and globally unique.

- **`~/.kube/config` is generated, not edited**
  - The main kubeconfig is derived state.
  - It can be deleted and regenerated at any time.

- **Environment boundaries are explicit**
  - Clusters are grouped into environments (e.g. prod, staging, dev).
  - There is no reliance on “current context” guessing.

---

## Directory Layout

```text
~/.kube/
├── config                  # GENERATED – do not edit
├── clusters/               # Source-of-truth kubeconfigs (one per cluster)
│   ├── k3s-prod.yaml
│   ├── k3s-staging.yaml
│   └── k3s-dev.yaml
├── envs/                   # Environment definitions
│   ├── prod
│   ├── staging
│   └── dev
├── bin/
│   ├── kubeconfig-hygiene.sh
│   └── kubeconfig-generate.sh
└── Makefile
