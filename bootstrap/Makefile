cluster := devcluster
crds := helmfile.d/01-crds.yaml
releases := helmfile.d/02-releases.yaml
appset := test-appset.yaml
argons := argocd
keys := /home/gary/.config/sops/age/keys.txt

all: cluster install

install: secrets crds apps appset

check: lint

clean: clean-cluster

crds:
	helmfile -f $(crds) sync
#	helmfile -f $(crds) template -q |\
#	yq ea --exit-status 'select(.kind == "CustomResourceDefinition")' |\
#	kubectl apply --server-side -f -
#
secrets: sops-age-key

sops-age-key:
	kubectl create ns $(argons)
	kubectl create secret generic argocd-age-secret-keys --namespace=$(argons) --from-file=$(keys)

apps: secrets crds sync

sync apply lint:
	helmfile -f $(releases) $@

appset:
	kubectl apply -f $(appset)

cluster: clean-cluster
	k3d cluster create $(cluster) --servers 3 --k3s-arg "--disable=traefik@server:*" --k3s-arg "--disable=servicelb@server:*"

clean-cluster:
	k3d cluster delete $(cluster)
