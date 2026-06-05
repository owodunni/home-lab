# Development and deployment automation for Pi cluster home lab
# Fix macOS fork safety issue with Python 3.13 + Ansible multiprocessing
ANSIBLE_PLAYBOOK = OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ANSIBLE_ROLES_PATH=$(CURDIR)/roles:~/.ansible/roles  uv run ansible-playbook

.PHONY: help setup vault-edit site system networking storage security disk-encrypt snapraid-mergerfs wireguard

help:
	@echo "🏠 Pi Cluster Home Lab - Available Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## 🔧 Install all dependencies (Python + Ansible collections + roles)
	uv sync
	uv run ansible-galaxy collection install -r requirements.yml
	uv run ansible-galaxy role install -r requirements.yml
	uv run pre-commit install

lint: ## 🔍 Run all linting and syntax checks
	@echo "Running yamllint..."
	uv run yamllint .
	@echo "Running ansible-lint..."
	uv run ansible-lint
	@echo "Checking Ansible syntax..."
	$(ANSIBLE_PLAYBOOK) --syntax-check playbooks/*.yml

precommit: ## 🚀 Run pre-commit hooks on staged files
	@echo "Running pre-commit hooks on staged files..."
	uv run pre-commit run

vault-edit: ## 🔐 Edit the encrypted secrets file (group_vars/all/vault.yml)
	@echo "Opening encrypted vault for editing..."
	uv run ansible-vault edit group_vars/all/vault.yml

upgrade: ## 📦 Run system upgrade playbook on all servers
	@echo "Running system upgrade playbook on all servers..."
	$(ANSIBLE_PLAYBOOK) playbooks/upgrade.yml

unattended-upgrades: ## 🔄 Setup unattended upgrades on all servers
	@echo "Setting up unattended upgrades on all servers..."
	$(ANSIBLE_PLAYBOOK) playbooks/unattended-upgrades.yml

pi-base-config: ## ⚙️ Configure Pi CM5 base settings and power optimization
	@echo "Configuring Pi CM5 base settings and power optimization..."
	$(ANSIBLE_PLAYBOOK) playbooks/pi-base-config.yml --diff

# Orchestration layers — each runs its function playbooks in sequence.
# Layers and the site playbook are composition only; they add no logic.
system: ## 🧱 System layer: updates + Pi CM5 hardware/firmware config
	@echo "Running system layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/system.yml

disk-encrypt: ## 🔐 Set up LUKS encryption on storage drives
	@echo "Setting up LUKS encryption on storage drives..."
	$(ANSIBLE_PLAYBOOK) playbooks/disk-encrypt.yml

snapraid-mergerfs: ## 💽 Install and configure MergerFS + SnapRAID storage pool
	@echo "Configuring MergerFS + SnapRAID storage pool..."
	$(ANSIBLE_PLAYBOOK) playbooks/snapraid-mergerfs.yml

wireguard: ## 🔑 Configure WireGuard peer on offsite storage hosts
	@echo "Configuring WireGuard peers..."
	$(ANSIBLE_PLAYBOOK) playbooks/wireguard.yml

networking: ## 🌐 Networking layer: WireGuard peers for cross-site connectivity
	@echo "Running networking layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/networking.yml

storage: ## 🗄️ Storage layer: encrypt drives + configure MergerFS/SnapRAID pool
	@echo "Running storage layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/storage.yml

security: ## 🔒 Security layer: unattended upgrades (firewall/SSH to come)
	@echo "Running security layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/security.yml

site: ## 🏗️ Full provisioning: run all layers in sequence (system → networking → storage → security)
	@echo "Running full site provisioning..."
	$(ANSIBLE_PLAYBOOK) site.yml
