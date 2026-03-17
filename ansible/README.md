# Cluster GitOps - Ansible Platform

This directory contains the Ansible automation for provisioning K3s clusters on LXD and bootstrapping the GitOps platform.

## Prerequisites
- `ansible` (with `kubernetes.core` collection)
- `lxc` / `lxd`
- `helmfile`
- `yq`
- `sops` (configured with `age`)

## Workflow
1. **Provision/Bootstrap**: `make bootstrap`
2. **Clean Cluster**: `make clean`
3. **App Install**: `make install`

## Architecture
- `roles/k3s_cluster`: Provisioning LXC nodes and joining K3s cluster.
- `roles/platform_apps`: Namespace creation, secret injection, and Helmfile sync.
- `inventory/group_vars/`: Global and environment-specific configuration.
