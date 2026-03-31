# ansible/Makefile
.PHONY: help deps provision provision-container provision-vm configure-lxd deploy-apps teardown teardown-container teardown-vm check lint all clean recreate status

# Default target when just running 'make'
help:
	@echo "Available targets:"
	@echo ""
	@echo "📦 Dependencies:"
	@echo "  deps          - Install required Ansible collections from requirements.yaml"
	@echo ""
	@echo "🚀 Provisioning:"
	@echo "  provision     - Provision K3s cluster (default: container)"
	@echo "  provision-container - Provision K3s cluster using LXC containers"
	@echo "  provision-vm  - Provision K3s cluster using LXC VMs"
	@echo ""
	@echo "🔧 Configuration:"
	@echo "  configure-lxd - Configure LXD default profile with ID mappings"
	@echo "  deploy-apps   - Install Kubernetes platform applications"
	@echo ""
	@echo "💥 Teardown:"
	@echo "  teardown      - Destroy K3s cluster (default: container)"
	@echo "  teardown-container - Destroy container-based K3s cluster"
	@echo "  teardown-vm   - Destroy VM-based K3s cluster"
	@echo ""
	@echo "🔍 Quality:"
	@echo "  check         - Run provision playbook in check mode (dry run)"
	@echo "  lint          - Run ansible-lint on all playbooks"
	@echo ""
	@echo "⚡ Utilities:"
	@echo "  all           - Run deps + provision (container-based)"
	@echo "  recreate      - Quick recreate of container cluster (teardown + provision)"
	@echo "  recreate-vm   - Quick recreate of VM cluster (teardown + provision)"
	@echo "  status        - Show cluster status (if available)"
	@echo "  clean         - Clean up temporary files"

# Install dependencies
deps:
	@echo "📦 Installing Ansible collections..."
	ansible-galaxy collection install -r requirements.yaml
	@echo "✅ Dependencies installed"

# Main provisioning (default to container for backward compatibility)
provision: provision-container
	@echo "✅ Container cluster provisioned"

provision-container:
	@echo "🚀 Provisioning K3s cluster with LXC containers..."
	ansible-playbook playbooks/provision-cluster.yaml -e runtime_type=container

provision-vm:
	@echo "🚀 Provisioning K3s cluster with LXC VMs..."
	@echo "⚠️  Note: VMs require more resources and take longer to boot"
	ansible-playbook playbooks/provision-cluster.yaml -e runtime_type=vm

# Configure LXD profile
configure-lxd:
	@echo "🔧 Configuring LXD default profile..."
	ansible-playbook playbooks/configure-lxd-profile.yaml

# Deploy platform apps (auto-detects runtime)
deploy-apps:
	@echo "📦 Installing Kubernetes platform applications..."
	ansible-playbook playbooks/deploy-platform-apps.yaml

# Teardown operations
teardown: teardown-container
	@echo "✅ Container cluster destroyed"

teardown-container:
	@echo "⚠️  WARNING: This will destroy your container-based K3s cluster!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		ansible-playbook playbooks/teardown-cluster.yaml -e "runtime_type=container remove_profile=false remove_kubeconfig=false"; \
	else \
		echo "Teardown cancelled."; \
	fi

teardown-vm:
	@echo "⚠️  WARNING: This will destroy your VM-based K3s cluster!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		ansible-playbook playbooks/teardown-cluster.yaml -e "runtime_type=vm remove_profile=true remove_kubeconfig=true"; \
	else \
		echo "Teardown cancelled."; \
	fi

# Full teardown with cleanup (remove profiles and kubeconfig)
teardown-full-container:
	@echo "⚠️  WARNING: This will destroy your container cluster and remove profiles/kubeconfig!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		ansible-playbook playbooks/teardown-cluster.yaml -e "runtime_type=container remove_profile=true remove_kubeconfig=true"; \
	else \
		echo "Teardown cancelled."; \
	fi

teardown-full-vm:
	@echo "⚠️  WARNING: This will destroy your VM cluster and remove profiles/kubeconfig!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		ansible-playbook playbooks/teardown-cluster.yaml -e "runtime_type=vm remove_profile=true remove_kubeconfig=true"; \
	else \
		echo "Teardown cancelled."; \
	fi

# Check/dry run mode (supports both runtimes)
check:
	@echo "🔍 Running in check mode (default: container)..."
	ansible-playbook playbooks/provision-cluster.yaml --check -e runtime_type=container

check-vm:
	@echo "🔍 Running in check mode for VMs..."
	ansible-playbook playbooks/provision-cluster.yaml --check -e runtime_type=vm

# Lint all playbooks
lint:
	@echo "🔎 Linting playbooks..."
	ansible-lint playbooks/*.yaml
	@echo "🔎 Linting roles..."
	ansible-lint roles/*/tasks/*.yaml 2>/dev/null || true

# Full pipeline (default to container)
all: deps provision-container

# Clean up temp files
clean:
	@echo "🧹 Cleaning up..."
	rm -f *.retry
	find . -name "*.pyc" -delete
	find . -name "*.bak" -delete
	@echo "✅ Cleanup complete"

# Quick recreation (for development)
recreate: teardown-container provision-container
	@echo "🔄 Container cluster recreated"

recreate-vm: teardown-vm provision-vm
	@echo "🔄 VM cluster recreated"

# Quick recreation with full cleanup
recreate-full: teardown-full-container provision-container
	@echo "🔄 Container cluster recreated with cleanup"

recreate-full-vm: teardown-full-vm provision-vm
	@echo "🔄 VM cluster recreated with cleanup"

# Get cluster info
status:
	@echo "📊 Cluster status..."
	@if lxc info k3s-c1 &>/dev/null 2>&1; then \
		echo "Container cluster detected:"; \
		lxc exec k3s-c1 -- kubectl get nodes 2>/dev/null || echo "  Cluster not ready"; \
	elif lxc info k3s-vm-1 &>/dev/null 2>&1; then \
		echo "VM cluster detected:"; \
		lxc exec k3s-vm-1 -- kubectl get nodes 2>/dev/null || echo "  Cluster not ready"; \
	else \
		echo "No cluster found. Run 'make provision-container' or 'make provision-vm'"; \
	fi

# Show node IPs (useful for debugging)
ips:
	@echo "🌐 Container IPs:"
	@lxc list k3s-c* -c n,4 --format csv 2>/dev/null || echo "  No container cluster found"
	@echo ""
	@echo "🌐 VM IPs:"
	@lxc list k3s-vm* -c n,4 --format csv 2>/dev/null || echo "  No VM cluster found"

# Show resource usage
resources:
	@echo "📊 Resource usage:"
	@lxc list --columns=n,s,4,5,6,8 -c n,s,4,5,6,8 2>/dev/null | grep -E "k3s-|NAME"

# Quick test both runtimes (for CI/testing)
test-both:
	@echo "🧪 Testing container cluster..."
	@make provision-container > /dev/null 2>&1 && \
		sleep 30 && \
		make status && \
		make teardown-container <<< "y" > /dev/null 2>&1 && \
		echo "✅ Container cluster test passed"
	@echo ""
	@echo "🧪 Testing VM cluster..."
	@make provision-vm > /dev/null 2>&1 && \
		sleep 60 && \
		make status && \
		make teardown-vm <<< "y" > /dev/null 2>&1 && \
		echo "✅ VM cluster test passed"

# Development helper - switch between branches
switch-to-container:
	@echo "Switching to container configuration..."
	@sed -i.bak 's/runtime_type:.*/runtime_type: "container"/' inventory/group_vars/k3s_cluster.yaml
	@echo "✅ Switched to container runtime"

switch-to-vm:
	@echo "Switching to VM configuration..."
	@sed -i.bak 's/runtime_type:.*/runtime_type: "vm"/' inventory/group_vars/k3s_cluster.yaml
	@echo "✅ Switched to VM runtime"

# Show current configuration
config:
	@echo "Current configuration:"
	@echo "  Runtime: $$(grep runtime_type inventory/group_vars/k3s_cluster.yaml 2>/dev/null | cut -d'"' -f2 || echo 'not set')"
	@echo "  Branch: $$(git branch --show-current)"
	@echo "  LXD Storage: $$(lxc storage list --format csv | head -1 | cut -d',' -f1)"
	@echo "  LXD Network: $$(lxc network list --format csv | head -1 | cut -d',' -f1)"
