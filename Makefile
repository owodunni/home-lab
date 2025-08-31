# Development and deployment automation for Pi cluster home lab
# Fix macOS fork safety issue with Python 3.13 + Ansible multiprocessing
ANSIBLE_PLAYBOOK = OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ANSIBLE_ROLES_PATH=$(CURDIR)/roles:~/.ansible/roles  uv run ansible-playbook

.PHONY: help setup lint precommit upgrade unattended-upgrades pi-base-config pi-storage-config site-check site minio minio-uninstall k3s-cluster k3s-cluster-check k3s-uninstall k8s-apps k8s-apps-check teardown teardown-check

help:
	@echo "🏠 Pi Cluster Home Lab - Available Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## 🔧 Install all dependencies (Python + Ansible collections + roles)
	uv sync
	uv run ansible-galaxy collection install -r requirements.yml
	uv run ansible-galaxy role install -r requirements.yml

lint: ## 🔍 Run all linting and syntax checks
	@echo "Running yamllint..."
	uv run yamllint .
	@echo "Running ansible-lint..."
	ANSIBLE_VAULT_PASSWORD_FILE=vault_passwords/all.txt uv run ansible-lint
	@echo "Checking Ansible syntax..."
	$(ANSIBLE_PLAYBOOK) --syntax-check playbooks/*.yml

precommit: ## 🚀 Run pre-commit hooks on staged files
	@echo "Running pre-commit hooks on staged files..."
	uv run pre-commit run

upgrade: ## 📦 Run system upgrade playbook on all servers
	@echo "Running system upgrade playbook on all servers..."
	$(ANSIBLE_PLAYBOOK) playbooks/upgrade.yml

unattended-upgrades: ## 🔄 Setup unattended upgrades on all servers
	@echo "Setting up unattended upgrades on all servers..."
	$(ANSIBLE_PLAYBOOK) playbooks/unattended-upgrades.yml

pi-base-config: ## ⚙️ Configure Pi CM5 base settings and power optimization
	@echo "Configuring Pi CM5 base settings and power optimization..."
	$(ANSIBLE_PLAYBOOK) playbooks/pi-base-config.yml --diff

pi-storage-config: ## 💾 Configure Pi CM5 storage settings
	@echo "Configuring Pi CM5 storage settings..."
	$(ANSIBLE_PLAYBOOK) playbooks/pi-storage-config.yml --diff

site-check: ## 🔎 Run full infrastructure setup in dry-run mode with diff
	@echo "Running full infrastructure setup (dry-run with diff)..."
	$(ANSIBLE_PLAYBOOK) site.yml --check --diff

site: ## 🏗️ Run full infrastructure setup
	@echo "Running full infrastructure setup..."
	$(ANSIBLE_PLAYBOOK) site.yml

minio: ## 🗄️ Complete MinIO installation with SSL certificates (HTTPS on port 443)
	@echo "Installing MinIO with SSL certificates..."
	$(ANSIBLE_PLAYBOOK) playbooks/minio-complete.yml --diff

minio-uninstall: ## 💣 Complete MinIO uninstall (service + SSL certificates + certbot cleanup)
	@echo "Uninstalling MinIO service and SSL certificates..."
	$(ANSIBLE_PLAYBOOK) playbooks/minio-uninstall.yml

k3s: ## ⚡ Deploy complete K3s infrastructure (all phases)
	@echo "Deploying complete K3s infrastructure..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s/k3s-complete.yml --diff

k3s-check: ## 🔍 Check complete K3s deployment (dry-run)
	@echo "Checking complete K3s deployment (dry-run)..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s/k3s-complete.yml --check --diff

k3s-teardown: ## 🧹 Completely uninstall K3s from all cluster nodes
	@echo "Uninstalling K3s from all cluster nodes..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s-uninstall.yml

k8s-apps: ## 🚀 Deploy Kubernetes applications (cert-manager + MinIO SSL)
	@echo "Deploying Kubernetes applications..."
	$(ANSIBLE_PLAYBOOK) playbooks/k8s-applications.yml --diff

k8s-apps-check: ## 🔍 Check Kubernetes applications deployment (dry-run)
	@echo "Checking Kubernetes applications deployment (dry-run)..."
	$(ANSIBLE_PLAYBOOK) playbooks/k8s-applications.yml --check --diff


teardown-check: ## 🔍 Preview infrastructure teardown (dry-run with diff)
	@echo "⚠️ PREVIEW: Infrastructure Teardown (dry-run)"
	@echo "This will show what would be removed:"
	@echo "• K3s cluster from all cluster nodes"
	@echo "• MinIO service and SSL certificates from NAS"
	@echo "• Kubernetes applications"
	@echo ""
	@echo "Running teardown preview..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s-uninstall.yml --check --diff
	$(ANSIBLE_PLAYBOOK) playbooks/minio-uninstall.yml --check --diff

teardown: ## 💣 Complete infrastructure teardown (K3s + MinIO + certificates)
	@echo "⚠️ WARNING: Complete Infrastructure Teardown"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "This will REMOVE:"
	@echo "• K3s cluster from all cluster nodes (pi-cm5-1, pi-cm5-2, pi-cm5-3)"
	@echo "• MinIO service and data from NAS node (pi-cm5-4)"
	@echo "• SSL certificates and Let's Encrypt configurations"
	@echo "• Kubernetes applications and configurations"
	@echo ""
	@echo "This will PRESERVE:"
	@echo "• Pi base configurations and optimizations"
	@echo "• Storage/disk configurations and mounts"
	@echo "• Unattended upgrade configurations"
	@echo "• System users and SSH access"
	@echo ""
	@read -p "Are you sure you want to proceed? (yes/no): " answer && [ "$$answer" = "yes" ] || (echo "Teardown cancelled." && exit 1)
	@echo ""
	@echo "Phase 1: Uninstalling Kubernetes applications..."
	-$(ANSIBLE_PLAYBOOK) playbooks/k8s-applications.yml --tags=uninstall
	@echo ""
	@echo "Phase 2: Uninstalling K3s cluster..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s-uninstall.yml
	@echo ""
	@echo "Phase 3: Uninstalling MinIO and certificates..."
	$(ANSIBLE_PLAYBOOK) playbooks/minio-uninstall.yml
	@echo ""
	@echo "🏁 Infrastructure teardown complete!"
	@echo "Base Pi configurations preserved. Ready for fresh deployment with 'make site'"
