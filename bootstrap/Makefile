cluster := dev
crds := bootstrap/01-crds.yaml
releases := bootstrap/02-releases.yaml
appset := bootstrap-handover.yaml
argons := argocd
keys := /home/gary/.config/sops/age/keys.txt
kubeconfig := ~/.kube/configs/k3s-lxc.yaml

all: cluster install

install: preflight secrets crds apps appset

check: lint

clean: clean-cluster

crds:
	helmfile --kubeconfig ${kubeconfig} -f $(crds) sync
#	helmfile --kubeconfig ${kubeconfig} -f $(crds) template -q |\
#	yq ea --exit-status 'select(.kind == "CustomResourceDefinition")' |\
#	kubectl --kubeconfig ${kubeconfig} apply --server-side -f -
#
secrets: sops-age-key

sops-age-key:
	kubectl --kubeconfig ${kubeconfig} create ns $(argons)
	kubectl --kubeconfig ${kubeconfig} create secret generic argocd-age-secret-keys --namespace=$(argons) --from-file=$(keys)

apps: secrets crds sync

preflight:
	kubectl --kubeconfig ${kubeconfig} get nodes | grep Ready

sync apply lint:
	helmfile --kubeconfig ${kubeconfig} -f $(releases) $@

appset:
	kubectl --kubeconfig ${kubeconfig} apply -f $(appset)

cluster: clean-cluster
cluster: clean-cluster
	@echo ">>> Bootstrapping k3s LXC cluster"
	HANDOVER_FILE=$(HANDOVER) bash ./bootstrap-k3s-lxc-cluster.sh

	@echo ">>> Loading bootstrap handover"
	@. ./$(HANDOVER) && \
	mkdir -p $$(dirname $(KUBECONFIG)) && \
	lxc exec $${FIRST_REMOTE}:$${FIRST_NODE} -- cat /etc/rancher/k3s/k3s.yaml \
	  | sed "s/127.0.0.1/$${FIRST_IP}/" \
	  > $(KUBECONFIG)

	@echo ">>> kubeconfig written to $(KUBECONFIG)"

clean-cluster:
	echo TDOO
