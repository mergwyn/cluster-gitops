cluster := k3s-dev
crds := initial-apps/01-crds.yaml
releases := initial-apps/02-releases.yaml
appset := bootstrap-handover.yaml
handover := bootstrap.env
argons := argocd
keys := /home/gary/.config/sops/age/keys.txt
kubeconfig := ~/.kube/clusters/$(cluster).yaml


all: cluster install

install: preflight secrets crds apps appset

check: lint

clean: clean-cluster

crds:
	helmfile --kubeconfig ${kubeconfig} -f $(crds) sync

secrets: sops-age-key

sops-age-key:
	-kubectl --kubeconfig ${kubeconfig} create ns $(argons)
	kubectl --kubeconfig ${kubeconfig} create secret generic argocd-age-secret-keys --namespace=$(argons) --from-file=$(keys)

apps: secrets crds sync

preflight:
	kubectl --kubeconfig ${kubeconfig} get nodes | grep Ready

sync apply lint:
	helmfile --kubeconfig ${kubeconfig} -f $(releases) $@

appset:
	kubectl --kubeconfig ${kubeconfig} apply -f $(appset)

cluster: clean-cluster
	@echo ">>> Bootstrapping k3s LXC cluster"
	HANDOVER_FILE=$(handover) bash ./bootstrap-k3s-lxc-cluster.sh $(cluster)

	@echo ">>> Loading bootstrap handover"
	mkdir -p $$(dirname $(kubeconfig))
	. ./$(handover) && \
	lxc exec $${FIRST_REMOTE}:$${FIRST_NODE} -- cat /etc/rancher/k3s/k3s.yaml \
	  | sed "s/127.0.0.1/$${FIRST_IP}/" \
	  > $(kubeconfig)
	chmod og-rwx $(kubeconfig)
	@echo ">>> kubeconfig written to $(kubeconfig)"

clean-cluster:
	@echo ">>> Cleaning $(cluster) LXC cluster"
	@sh -ec '. ./$(handover); \
	for node in $$CLUSTER; do \
	if lxc info $${node} >/dev/null 2>&1; then \
		echo $$node is active, deleting; lxc stop $${node}; lxc delete $${node}; \
	else \
		echo $$node is not running; \
	fi; \
	done'
