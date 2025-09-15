apps: secrets sync

sync:
	helmfile sync 

secrets: sops-age-key

sops-age-key:
# TODO create NS?
	kubectl create ns argocd
	kubectl create secret generic sops-age-key --namespace=argocd --from-file=/home/gary/.config/sops/age/keys.txt

