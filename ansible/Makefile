# ansible/Makefile
.PHONY: help deps provision configure-lxd deploy-apps teardown check lint all

# Default target when just running 'make'
help:
	@echo "Available targets:"
	@echo "  deps          - Install required Ansible collections from requirements.yaml"
	@echo "  provision     - Provision K3s cluster and deploy platform apps"
	@echo "  configure-lxd - Configure LXD default profile with ID mappings"
	@echo "  deploy-apps   - Install k8s apps"
	@echo "  teardown      - Destroy K3s cluster (with confirmation)"
	@echo "  check         - Run playbooks in check mode (dry run)"
	@echo "  lint          - Run ansible-lint on all playbooks"
	@echo "  all           - Run deps + provision"

# Install dependencies
deps:
	@echo "📦 Installing Ansible collections..."
	ansible-galaxy collection install -r requirements.yaml
	@echo "✅ Dependencies installed"

# Main provisioning
provision: deps
	@echo "🚀 Provisioning K3s cluster..."
	ansible-playbook playbooks/provision-cluster.yaml

# Configure LXD profile
configure-lxd:
	@echo "🔧 Configuring LXD default profile..."
	ansible-playbook playbooks/configure-lxd-profile.yaml

deploy-apps:
	@echo "📦 Installing Kubernetes apps..."
	ansible-playbook playbooks/deploy-platform-apps.yaml

# Teardown with safety confirmation
teardown:
	@echo "⚠️  WARNING: This will destroy your K3s cluster!"
	ansible-playbook playbooks/teardown-cluster.yaml

# Check/dry run mode
check:
	@echo "🔍 Running in check mode..."
	ansible-playbook playbooks/provision-cluster.yaml --check

# Lint all playbooks
lint:
	@echo "🔎 Linting playbooks..."
	ansible-lint playbooks/*.yaml

# Full pipeline
all: deps provision

# Optional: Clean up (if you have any temp files to remove)
clean:
	@echo "🧹 Cleaning up..."
	rm -f *.retry
	find . -name "*.pyc" -delete

# For local development - quick recreate
recreate: teardown provision
	@echo "🔄 Cluster recreated"

# Get cluster info (if you add a status playbook later)
status:
	@echo "📊 Cluster status..."
	@if [ -f playbooks/status.yaml ]; then \
		ansible-playbook playbooks/status.yaml; \
	else \
		echo "No status playbook found. Create playbooks/status.yaml to use this target."; \
	fi
