env := dev
type := k3s
platform := lxc
cluster := $(type)-$(env)
crds := helmfile.d/01-crds.yaml
releases := helmfile.d/02-releases.yaml
appset := bootstrap-handover.yaml
handover := bootstrap.env
argons := argocd
keys := /home/gary/.config/sops/age/keys.txt
config := ~/.kube/clusters/$(cluster).yaml
kubectl := kubectl --kubeconfig ${config}
helmfile := helmfile --kubeconfig ${config}


all: cluster install

install: preflight secrets apps appset

check: lint

clean: clean-cluster

secrets: sops-age-key

sops-age-key:
	-$(kubectl) create ns $(argons)
	$(kubectl) create secret generic argocd-age-secret-keys --namespace=$(argons) --from-file=$(keys)

apps: secrets sync

preflight:
	$(kubectl) get nodes | grep Ready

sync apply lint:
	$(helmfile) $@

appset:
	$(kubectl) apply -f $(appset)

cluster: #clean-cluster
	@echo ">>> Bootstrapping k3s LXC cluster"
	HANDOVER_FILE=$(handover) bash ./bootstrap-k3s-lxc-cluster.sh $(cluster)

	@echo ">>> Loading bootstrap handover"
	mkdir -p $$(dirname $(config))
	. ./$(handover) && \
	lxc exec $${FIRST_REMOTE}:$${FIRST_NODE} -- cat /etc/rancher/k3s/k3s.yaml \
	  | sed "s/127.0.0.1/$${FIRST_IP}/" \
	  > $(config)

	@echo ">>> Running kubeconfig hygiene"
	./scripts/kubeconfig-hygiene.sh \
	  $(config) \
	  $(cluster) \
	  $(argons)

	chmod 600 $(config)
	@echo ">>> kubeconfig written to $(config)"


clean-cluster:
	@echo ">>> Cleaning $(cluster) LXC cluster"
	@sh -ec 'if [ -f "$(handover)" ] ; then \
		. ./$(handover); \
		for node in $$CLUSTER; do \
			if lxc info $${node} >/dev/null 2>&1; then \
				echo $$node is active, deleting; lxc stop $${node}; lxc delete $${node}; \
			else \
				echo $$node is not running; \
			fi; \
		done; \
	fi'
