# Development and deployment automation for Pi cluster home lab
# Fix macOS fork safety issue with Python 3.13 + Ansible multiprocessing
ANSIBLE_PLAYBOOK = OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ANSIBLE_ROLES_PATH=$(CURDIR)/roles:~/.ansible/roles  uv run ansible-playbook

.PHONY: help setup vault-edit site system networking storage ingress traefik auth authentik services service-infra docker garage monitoring node-exporter smartctl-exporter prometheus grafana security disk-encrypt snapraid-mergerfs nfs disk-spindown wireguard seafile applications gpu-drivers media-storage media-forward-auth qbittorrent

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

nfs: ## 📂 Export the storage pool over NFS + install client on the Docker fleet
	@echo "Configuring NFS server and clients..."
	$(ANSIBLE_PLAYBOOK) playbooks/nfs.yml

disk-spindown: ## 💤 Configure HDD spin-down on idle storage drives
	@echo "Configuring HDD spin-down..."
	$(ANSIBLE_PLAYBOOK) playbooks/disk-spindown.yml

wireguard: ## 🔑 Configure WireGuard peers on [wireguard] group hosts
	@echo "Configuring WireGuard peers..."
	$(ANSIBLE_PLAYBOOK) playbooks/wireguard.yml

networking: ## 🌐 Networking layer: WireGuard peers for cross-site connectivity
	@echo "Running networking layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/networking.yml

storage: ## 🗄️ Storage layer: encrypt drives + configure MergerFS/SnapRAID pool
	@echo "Running storage layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/storage.yml

traefik: ## 🔀 Install Traefik reverse proxy with ACME on [ingress] hosts
	@echo "Configuring Traefik..."
	$(ANSIBLE_PLAYBOOK) playbooks/traefik.yml

ingress: ## 🌍 Ingress layer: Traefik + ACME wildcard certificates
	@echo "Running ingress layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/ingress.yml

docker: ## 🐳 Install Docker + Compose on [services] hosts
	@echo "Installing Docker on the service fleet..."
	$(ANSIBLE_PLAYBOOK) playbooks/docker.yml

service-infra: ## 🧩 Service-infra layer: Docker runtime for application services
	@echo "Running service-infra layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/service-infra.yml

authentik: ## 🔐 Install Authentik identity provider on [authentik] hosts
	@echo "Configuring Authentik..."
	$(ANSIBLE_PLAYBOOK) playbooks/authentik.yml

auth: ## 🛡️ Auth layer: Authentik SSO/OIDC identity provider
	@echo "Running auth layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/auth.yml

garage: ## 🗃️ Install Garage S3-compatible object storage on [ingress] hosts
	@echo "Configuring Garage..."
	$(ANSIBLE_PLAYBOOK) playbooks/garage.yml

services: ## 📦 Services layer: Garage S3 object storage
	@echo "Running services layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/services.yml

node-exporter: ## 📡 Deploy Prometheus node_exporter on all fleet hosts
	@echo "Deploying node_exporter on all fleet hosts..."
	$(ANSIBLE_PLAYBOOK) playbooks/node-exporter.yml

smartctl-exporter: ## 💿 Deploy smartctl_exporter (SMART drive health) on [storage] hosts
	@echo "Deploying smartctl_exporter on storage hosts..."
	$(ANSIBLE_PLAYBOOK) playbooks/smartctl-exporter.yml

prometheus: ## 📈 Install Prometheus and Alertmanager on [monitoring] hosts
	@echo "Configuring Prometheus and Alertmanager..."
	$(ANSIBLE_PLAYBOOK) playbooks/prometheus.yml

grafana: ## 📊 Install Grafana on [monitoring] hosts
	@echo "Configuring Grafana..."
	$(ANSIBLE_PLAYBOOK) playbooks/grafana.yml

monitoring: ## 🔭 Monitoring layer: node_exporter + Prometheus + Alertmanager + Grafana
	@echo "Running monitoring layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/monitoring.yml

seafile: ## 🗂️ Install Seafile file sync/share on [seafile] hosts (data on NFS)
	@echo "Configuring Seafile..."
	$(ANSIBLE_PLAYBOOK) playbooks/seafile.yml

gpu-drivers: ## 🎬 Install Intel GPU drivers (QuickSync/VA-API) on [media] hosts
	@echo "Installing Intel GPU drivers on the media host..."
	$(ANSIBLE_PLAYBOOK) playbooks/gpu-drivers.yml

media-storage: ## 🎞️ Create the shared media data tree on the pool ([media] hosts)
	@echo "Provisioning the media storage layout..."
	$(ANSIBLE_PLAYBOOK) playbooks/media-storage.yml

media-forward-auth: ## 🔐 Deploy the Authentik forward-auth middleware on [media] hosts
	@echo "Deploying the media forward-auth middleware..."
	$(ANSIBLE_PLAYBOOK) playbooks/media-forward-auth.yml

qbittorrent: ## ⬇️ Deploy qBittorrent + Gluetun VPN on [qbittorrent] hosts
	@echo "Deploying qBittorrent..."
	$(ANSIBLE_PLAYBOOK) playbooks/qbittorrent.yml

applications: ## 📂 Applications layer: end-user services (Seafile + media stack)
	@echo "Running applications layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/applications.yml

security: ## 🔒 Security layer: unattended upgrades (firewall/SSH to come)
	@echo "Running security layer..."
	$(ANSIBLE_PLAYBOOK) playbooks/security.yml

site: ## 🏗️ Full provisioning: all layers in sequence (system → networking → storage → ingress → service-infra → services → auth → monitoring → applications → security)
	@echo "Running full site provisioning..."
	$(ANSIBLE_PLAYBOOK) site.yml
