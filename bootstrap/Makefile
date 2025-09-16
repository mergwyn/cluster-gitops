cluster := devcluster
crds := crds-helmfile.yaml
releases := releases-helmfile
appset := test-appset.yaml
argons := argocd
keys := /home/gary/.config/sops/age/keys.txt

install: secrets crds apps appset

all: cluster install

check: lint

clean: clean-cluster

crds:
	helmfile -f $(crds) template -q |\
	yq ea --exit-status 'select(.kind == "CustomResourceDefinition")' |\
	kubectl apply --server-side -f -

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
	k3d cluster create $(cluster)  #--k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=servicelb@server:0"

clean-cluster:
	k3d cluster delete $(cluster)
