# Development and deployment automation for Pi cluster home lab
# Fix macOS fork safety issue with Python 3.13 + Ansible multiprocessing
ANSIBLE_PLAYBOOK = OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ANSIBLE_ROLES_PATH=$(CURDIR)/roles:~/.ansible/roles  uv run ansible-playbook

.PHONY: help setup lint precommit upgrade unattended-upgrades pi-base-config pi-storage-config site-check site minio-setup minio-uninstall nas-ssl k3s-cluster k3s-cluster-check k3s-uninstall k8s-apps k8s-apps-check

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

minio-setup: ## 🗄️ Install and configure MinIO S3 storage on NAS
	@echo "Installing MinIO S3 storage on NAS..."
	$(ANSIBLE_PLAYBOOK) playbooks/minio-setup.yml --diff

minio-uninstall: ## 🧹 Completely uninstall MinIO from NAS node
	@echo "Uninstalling MinIO from NAS node..."
	$(ANSIBLE_PLAYBOOK) playbooks/minio-uninstall.yml

k3s-cluster: ## ⚡ Deploy K3s HA cluster on Pi nodes
	@echo "Deploying K3s HA cluster..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s-cluster.yml --diff

k3s-cluster-check: ## 🔍 Check K3s cluster deployment (dry-run)
	@echo "Checking K3s cluster deployment (dry-run)..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s-cluster.yml --check --diff

k3s-uninstall: ## 🧹 Completely uninstall K3s from all cluster nodes
	@echo "Uninstalling K3s from all cluster nodes..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s-uninstall.yml

k8s-apps: ## 🚀 Deploy Kubernetes applications (cert-manager + MinIO SSL)
	@echo "Deploying Kubernetes applications..."
	$(ANSIBLE_PLAYBOOK) playbooks/k8s-applications.yml --diff

k8s-apps-check: ## 🔍 Check Kubernetes applications deployment (dry-run)
	@echo "Checking Kubernetes applications deployment (dry-run)..."
	$(ANSIBLE_PLAYBOOK) playbooks/k8s-applications.yml --check --diff

nas-ssl: ## 🔒 Setup SSL certificates and HTTPS for NAS services (port 443)
	@echo "Setting up SSL certificates and HTTPS for NAS services..."
	$(ANSIBLE_PLAYBOOK) playbooks/nas-ssl-setup.yml --diff
