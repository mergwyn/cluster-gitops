
apps: secrets crds sync appset

crds:
	helmfile -f crds-helmfile.yaml template -q | yq ea --exit-status 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side -f -

secrets: sops-age-key

sops-age-key:
# TODO create NS?
	kubectl create ns argocd
	kubectl create secret generic argocd-age-secret-keys --namespace=argocd --from-file=/home/gary/.config/sops/age/keys.txt

sync:
	helmfile -f releases-helmfile.yaml sync 

appset:
	kubectl apply -f test-appset.yaml

cluster: clean-cluster
	k3d cluster create devcluster  #--k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=servicelb@server:0"
clean-cluster:
	k3d cluster delete devcluster
