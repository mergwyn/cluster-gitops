#!/usr/bin/env bash

set -o nounset

chart=$1
namespace=$(basename $(dirname ${chart}))

kubectl kustomize --enable-helm  ${chart} |
  sed -e "s/namespace: *kube-system/namespace: ${namespace}/" | tee /tmp/helmchart |
  kubectl apply -n ${namespace} -f -

rm -rf ${chart}/charts
