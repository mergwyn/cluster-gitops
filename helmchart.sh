#!/usr/bin/env bash

set -o nounset

chart=$1
dirname ${chart}
basename $(dirname ${chart})
namespace=$(basename $(dirname ${chart}))
values=${chart}/values.yaml
release= # TODO use jq to get release from Chart.yaml
release=kube-vip

#namespace=kube-system
#chart=bootstrap/${namespace}/kube-vip
#values=${chart}/values.yaml
#release=kube-vip

helm dependency update --namespace ${namespace} ${chart}/
helm upgrade --create-namespace --namespace ${namespace} ${release} ${chart}/ \
  --values=settings/settings.yaml \
  --values=settings/dev.yaml \
  --values=${values} \
  --dry-run 
