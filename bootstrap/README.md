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
