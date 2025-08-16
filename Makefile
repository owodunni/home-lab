.PHONY: help install lint precommit

help: ## Show this help message
	@echo "Available commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

install: ## Install dependencies using UV
	@echo "Installing dependencies with UV..."
	uv sync

lint: ## Run YAML linting, Ansible linting, and syntax check
	@echo "Running yamllint..."
	uv run yamllint .
	@echo "Running ansible-lint..."
	uv run ansible-lint
	@echo "Checking Ansible syntax..."
	uv run ansible-playbook --syntax-check *.yml

precommit: ## Run pre-commit hooks on staged files
	@echo "Running pre-commit hooks..."
	uv run pre-commit run
