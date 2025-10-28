#!/usr/bin/env bash


if ! which helmfile >/dev/null ; then
# install helmfile
  curl -sSL https://raw.githubusercontent.com/upciti/wakemeops/main/assets/install_repository | sudo bash
  sudo apt install helmfile
  helmfile init --quiet
fi

namespace=argocd
release=argo-cd
path=bootstrap/${namespace}/${release}/

helmfile template --file ${path}/helmfile.yaml --namespace ${namespace}

echo kubectl apply -f prod-appset.yaml

echo Need to add bitwarden secret
