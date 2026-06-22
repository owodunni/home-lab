# Development and deployment automation for Pi cluster home lab
# Fix macOS fork safety issue with Python 3.13 + Ansible multiprocessing
ANSIBLE_PLAYBOOK = OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ANSIBLE_ROLES_PATH=$(CURDIR)/roles:~/.ansible/roles  uv run ansible-playbook

.PHONY: help setup lint precommit vault-edit \
        system networking storage ingress service-infra auth applications backup monitoring security site \
        app verify-backups restore-backups drill local-drill

help:
	@echo "🏠 Pi Cluster Home Lab - Available Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Utilities ──────────────────────────────────────────────────────────────
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

# ── Layers ─────────────────────────────────────────────────────────────────
# Each layer is a composition-only playbook that runs its function playbooks in
# sequence. To run a single function playbook on its own, invoke it directly:
#   $(ANSIBLE_PLAYBOOK) playbooks/<function>.yml
system: ## 🧱 System layer: package updates + Pi CM5 + Intel GPU hardware config
	@echo "Running system layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/system.yml

networking: ## 🌐 Networking layer: WireGuard peers for cross-site connectivity
	@echo "Running networking layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/networking.yml

storage: ## 🗄️ Storage layer: encrypted drives + MergerFS/SnapRAID pool + media tree
	@echo "Running storage layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/storage.yml

ingress: ## 🌍 Ingress layer: Traefik + ACME wildcard certificates
	@echo "Running ingress layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/ingress.yml

service-infra: ## 🧩 Service-infra layer: Docker runtime + Garage S3 backend
	@echo "Running service-infra layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/service-infra.yml

auth: ## 🛡️ Auth layer: Authentik SSO/OIDC identity provider
	@echo "Running auth layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/auth.yml

applications: ## 📂 Applications layer: end-user services (Nextcloud + media stack)
	@echo "Running applications layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/applications.yml

backup: ## 💾 Backup layer: offsite mirror of service backups (valen Garage → beelink)
	@echo "Running backup layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/backup.yml

monitoring: ## 🔭 Monitoring layer: node_exporter + Prometheus + Alertmanager + Grafana
	@echo "Running monitoring layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/monitoring.yml

security: ## 🔒 Security layer: unattended upgrades (firewall/SSH to come)
	@echo "Running security layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/security.yml

site: ## 🏗️ Full provisioning: all layers in sequence (system → networking → storage → ingress → service-infra → auth → applications → backup → monitoring → security)
	@echo "Running full site provisioning..."
	$(ANSIBLE_PLAYBOOK) site.yml

# ── Single application service ───────────────────────────────────────────────
# Deploy one service's function playbook by name, without running the whole
# applications layer. Convention: the inventory group, the function playbook
# filename, and the group_vars dir all share the service name, so the name is the
# only argument: `make app service=qbittorrent` runs playbooks/qbittorrent.yml.
# Accepts SERVICE= too (the case used by the backup targets), so either works.
app: ## 🚀 Deploy a single app service by name (service=<group>, e.g. service=qbittorrent)
	@svc="$(service)$(SERVICE)"; \
	test -n "$$svc" || { echo "Usage: make app service=<service-group>  (e.g. service=qbittorrent)"; exit 1; }; \
	test -f "playbooks/$$svc.yml" || { echo "No playbooks/$$svc.yml — '$$svc' is not a deployable service."; exit 1; }; \
	echo "Deploying $$svc..."; \
	$(ANSIBLE_PLAYBOOK) playbooks/$$svc.yml

# ── Backups ────────────────────────────────────────────────────────────────
verify-backups: ## ✅ Verify a service's backups exist and are fresh, and list every restore point (SERVICE=<group>)
	@test -n "$(SERVICE)" || { echo "Usage: make verify-backups SERVICE=<service-group>"; exit 1; }
	@echo "Verifying backups for $(SERVICE)..."
	$(ANSIBLE_PLAYBOOK) playbooks/verify-backups.yml -e backup_service=$(SERVICE)

drill: ## 🧪 Non-destructive restore drill: prove a service's backups restore (SERVICE=<group>)
	@test -n "$(SERVICE)" || { echo "Usage: make drill SERVICE=<service-group>"; exit 1; }
	@echo "Drilling restore for $(SERVICE) (non-destructive)..."
	$(ANSIBLE_PLAYBOOK) playbooks/drill-backups.yml -e backup_service=$(SERVICE)

local-drill: ## 🧪 Local restore drill: restore all (or one) service's backups to this workstation (SERVICE=<group>, optional)
	@echo "Running local restore drill..."
	@if [ -n "$(SERVICE)" ]; then \
	  scripts/local-drill.sh "$(SERVICE)"; \
	else \
	  scripts/local-drill.sh; \
	fi

restore-backups: ## ♻️ DESTRUCTIVE restore of a service's backups, typed confirm prompt (SERVICE=<group> [TARGETS='name=snap_id,...'])
	@test -n "$(SERVICE)" || { echo "Usage: make restore-backups SERVICE=<service-group> [TARGETS='name=snap_id,...']"; exit 1; }
	@echo "Restoring backups for $(SERVICE) (interactive confirmation required)..."
	@# TARGETS lets you roll back to an OLDER restore point per backup: pick
	@# snapshot IDs from `make verify-backups`, e.g. TARGETS='postgres=ab12cd34,volumes=ef56ab78'.
	@# Omit a backup (or TARGETS entirely) to restore its latest snapshot.
	@extra=""; \
	if [ -n "$(TARGETS)" ]; then \
	  map=$$(printf '%s' "$(TARGETS)" | tr ',' '\n' | sed '/^$$/d' | \
	    awk -F= 'BEGIN{printf "{"} {printf "%s\"%s\":\"%s\"",(NR>1?",":""),$$1,$$2} END{printf "}"}'); \
	  extra="-e {\"backup_targets\":$$map}"; \
	fi; \
	$(ANSIBLE_PLAYBOOK) playbooks/restore-backups.yml -e backup_service=$(SERVICE) $$extra
