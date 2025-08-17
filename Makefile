# Development and deployment automation for Pi cluster home lab
ANSIBLE_PLAYBOOK = uv run ansible-playbook

.PHONY: help setup lint precommit upgrade unattended-upgrades

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
