# Development and deployment automation for Pi cluster home lab
# Fix macOS fork safety issue with Python 3.13 + Ansible multiprocessing
ANSIBLE_PLAYBOOK = OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ANSIBLE_ROLES_PATH=$(CURDIR)/roles:~/.ansible/roles  uv run ansible-playbook

.PHONY: help setup lint precommit upgrade unattended-upgrades pi-base-config pi-storage-config site-check site

help:
	@echo "Available commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## Install all dependencies (Python + Ansible collections)
	uv sync
	uv run ansible-galaxy collection install -r requirements.yml

lint: ## Run all linting and syntax checks
	@echo "Running yamllint..."
	uv run yamllint .
	@echo "Running ansible-lint..."
	uv run ansible-lint
	@echo "Checking Ansible syntax..."
	$(ANSIBLE_PLAYBOOK) --syntax-check playbooks/*.yml

precommit:
	@echo "Running pre-commit hooks on staged files..."
	uv run pre-commit run

upgrade:
	@echo "Running system upgrade playbook on all servers..."
	$(ANSIBLE_PLAYBOOK) playbooks/upgrade.yml

unattended-upgrades:
	@echo "Setting up unattended upgrades on all servers..."
	$(ANSIBLE_PLAYBOOK) playbooks/unattended-upgrades.yml

pi-base-config:
	@echo "Configuring Pi CM5 base settings and power optimization..."
	$(ANSIBLE_PLAYBOOK) playbooks/pi-base-config.yml --check --diff

pi-storage-config:
	@echo "Configuring Pi CM5 storage settings..."
	$(ANSIBLE_PLAYBOOK) playbooks/pi-storage-config.yml --diff

site-check: ## Run full infrastructure setup in dry-run mode with diff
	@echo "Running full infrastructure setup (dry-run with diff)..."
	$(ANSIBLE_PLAYBOOK) site.yml --check --diff

site: ## Run full infrastructure setup
	@echo "Running full infrastructure setup..."
	$(ANSIBLE_PLAYBOOK) site.yml

minio-setup: ## Install and configure MinIO S3 storage on NAS
	@echo "Installing MinIO S3 storage on NAS..."
	$(ANSIBLE_PLAYBOOK) playbooks/minio-setup.yml --check --diff
