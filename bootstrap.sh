#!/usr/bin/env bash

namespace=argocd
release=argo-cd
values=bootstrap/${namespace}/${release}/values.yaml

helm dependency update --namespace ${namespace} ${chart}/
TODO Add repo
helm install --create-namespace --namespace ${namespace} ${release} ${chart}/ --values=${values} #--dry-run --skip-crds
kubectl apply -f dev-appset.yaml

TODO add secrets
