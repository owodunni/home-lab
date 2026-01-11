# Development and deployment automation for Pi cluster home lab
# Fix macOS fork safety issue with Python 3.13 + Ansible multiprocessing
ANSIBLE_PLAYBOOK = OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES ANSIBLE_ROLES_PATH=$(CURDIR)/roles:~/.ansible/roles  uv run ansible-playbook

.PHONY: help setup beelink-setup beelink-storage minio-storage nas-spindown backup-setup beelink-complete beelink-gpu-setup lint precommit upgrade unattended-upgrades pi-base-config pi-storage-config site-check site minio minio-uninstall k3s k3s-check k3s-helm-setup k3s-teardown k3s-cluster k3s-cluster-check k3s-uninstall kubeconfig-update lint-apps app-deploy app-upgrade app-list app-status app-delete apps-deploy-all teardown teardown-check

help:
	@echo "🏠 Pi Cluster Home Lab - Available Commands"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## 🔧 Install all dependencies (Python + Ansible collections + roles)
	uv sync
	uv run ansible-galaxy collection install -r requirements.yml
	uv run ansible-galaxy role install -r requirements.yml

beelink-setup: ## 🖥️ Configure passwordless sudo on beelink (first-time setup)
	@echo "Configuring passwordless sudo on beelink..."
	$(ANSIBLE_PLAYBOOK) playbooks/beelink/01-initial-setup.yml --ask-become-pass --limit beelink

beelink-storage: ## 💽 Configure MergerFS + SnapRAID storage on Beelink (2 data + 1 parity = 4TB)
	@echo "⚠️  WARNING: This will reconfigure NVMe drives on beelink!"
	@echo "ℹ️  Storage: MergerFS pool + SnapRAID parity (filesystem-based storage)"
	@echo ""
	@echo "Configured drives:"
	@echo "  - /dev/disk/by-id/nvme-CT2000P310SSD8_24454C177944 (disk1)"
	@echo "  - /dev/disk/by-id/nvme-CT2000P310SSD8_24454C37CB1B (disk2)"
	@echo "  - /dev/disk/by-id/nvme-CT2000P310SSD8_24454C40D38E (parity1)"
	@echo ""
	@echo "Result: /mnt/storage (4TB usable, NFS exported to K8s)"
	@echo ""
	@printf "Continue? (yes/no): " && read answer && [ "$$answer" = "yes" ] || (echo "Cancelled." && exit 1)
	@echo ""
	@echo "Configuring Beelink storage with LUKS + MergerFS + SnapRAID..."
	$(ANSIBLE_PLAYBOOK) playbooks/beelink/03-storage-reconfigure-mergerfs.yml --diff

minio-storage: ## 🗄️ Configure MergerFS + SnapRAID storage on MinIO NAS (1 data + 1 parity = 2TB)
	@echo "⚠️  WARNING: This will reconfigure storage on MinIO NAS!"
	@echo "ℹ️  Storage: MergerFS pool + SnapRAID parity for MinIO backup target"
	@echo ""
	@echo "Configured drives:"
	@echo "  - /dev/disk/by-id/wwn-0x5000c5008a1a78df (2TB data - minio-data1)"
	@echo "  - /dev/disk/by-id/wwn-0x5000c5008a1a7d0f (2TB parity - minio-par1)"
	@echo ""
	@echo "Result: /mnt/minio-storage (2TB usable, MinIO data + parity protection)"
	@echo ""
	@printf "Continue? (yes/no): " && read answer && [ "$$answer" = "yes" ] || (echo "Cancelled." && exit 1)
	@echo ""
	@echo "Configuring MinIO storage with MergerFS + SnapRAID..."
	$(ANSIBLE_PLAYBOOK) playbooks/nas/minio-storage-reconfigure.yml --diff

nas-spindown: ## ⏸️  Configure disk spin-down for MinIO NAS HDDs (30-minute timeout)
	@echo "Configuring disk spin-down for MinIO NAS storage..."
	@echo ""
	@echo "This will configure:"
	@echo "  - hdparm spin-down timeout: 30 minutes idle"
	@echo "  - APM level: 128 (balanced power/performance)"
	@echo "  - Persistent udev rules for automatic application"
	@echo ""
	@echo "Target drives:"
	@echo "  - wwn-0x5000c5008a1a78df (minio-disk1)"
	@echo "  - wwn-0x5000c5008a1a7d0f (minio-parity1)"
	@echo ""
	@echo "Expected power savings: ~11W during idle periods"
	@echo ""
	$(ANSIBLE_PLAYBOOK) playbooks/nas/minio-disk-spindown-setup.yml --diff

backup-setup: ## 📦 Setup restic backups and SnapRAID automation (run after storage setup)
	@echo "Setting up backup automation..."
	@echo ""
	@echo "This will configure:"
	@echo "  - restic backups to MinIO S3 (daily 3 AM)"
	@echo "  - Beelink SnapRAID sync (daily 4 AM)"
	@echo "  - MinIO SnapRAID sync (daily 5 AM)"
	@echo ""
	@echo "Phase 1: Beelink restic backup setup..."
	$(ANSIBLE_PLAYBOOK) playbooks/beelink/04-restic-backup-setup.yml --diff
	@echo ""
	@echo "Phase 2: Beelink SnapRAID automation..."
	$(ANSIBLE_PLAYBOOK) playbooks/beelink/05-snapraid-sync-setup.yml --diff
	@echo ""
	@echo "Phase 3: MinIO SnapRAID automation..."
	$(ANSIBLE_PLAYBOOK) playbooks/nas/minio-snapraid-sync-setup.yml --diff
	@echo ""
	@echo "✅ Backup automation configured successfully"

beelink-complete: ## 🖥️ Complete beelink server configuration (all phases)
	@echo "Running complete beelink server configuration..."
	$(ANSIBLE_PLAYBOOK) playbooks/beelink/beelink-complete.yml --ask-become-pass --limit beelink

beelink-gpu-setup: ## 🎬 Setup Intel GPU drivers for hardware transcoding (QuickSync)
	@echo "Installing Intel GPU drivers for hardware transcoding..."
	$(ANSIBLE_PLAYBOOK) playbooks/beelink/03-gpu-drivers-setup.yml --diff

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
	$(ANSIBLE_PLAYBOOK) playbooks/k3s/k3s-complete.yml --diff -v

k3s-check: ## 🔍 Check complete K3s deployment (dry-run)
	@echo "Checking complete K3s deployment (dry-run)..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s/k3s-complete.yml --check --diff

k3s-helm-setup: ## 📦 Configure Helm repositories on control plane
	@echo "Configuring Helm repositories..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s/02-helm-setup.yml --diff

k3s-teardown: ## 🧹 Completely uninstall K3s from all control plane nodes
	@echo "Uninstalling K3s from all control plane nodes..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s-uninstall.yml

kubeconfig-update: ## 🔑 Update local kubeconfig from control plane node
	@echo "Updating ~/.kube/config from control plane..."
	@mkdir -p ~/.kube
	@uv run ansible pi-cm5-1 -a "cat /etc/rancher/k3s/k3s.yaml" -b 2>/dev/null | \
		awk '/^apiVersion:/, /^$$/ {print}' | \
		sed 's|https://127.0.0.1:6443|https://pi-cm5-1:6443|' > ~/.kube/config
	@echo "✅ Kubeconfig updated successfully"
	@echo "Testing connection..."
	@kubectl cluster-info

verify-backups: ## 🔍 Verify MinIO backups exist before disaster recovery
	@echo "Verifying MinIO backup availability..."
	@echo ""
	@echo "📦 Checking MinIO S3 service..."
	@curl -f -s -o /dev/null https://minio.jardoole.xyz || \
		(echo "❌ ERROR: MinIO not accessible at https://minio.jardoole.xyz" && exit 1)
	@echo "✅ MinIO is accessible"
	@echo ""
	@echo "📋 Checking for Longhorn system backups..."
	@uv run ansible pi-cm5-4 -a "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/longhorn-system-backup/" 2>/dev/null | \
		grep -E '\.zip$$' | tail -5 || \
		(echo "❌ ERROR: No system backups found in MinIO!" && \
		 echo "   Expected location: longhorn-backups/backups/longhorn-system-backup/" && \
		 echo "   Cannot proceed with disaster recovery without backups." && exit 1)
	@echo ""
	@echo "✅ System backups found (showing 5 most recent):"
	@uv run ansible pi-cm5-4 -a "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/longhorn-system-backup/" 2>/dev/null | \
		grep -E '\.zip$$' | tail -5 | awk '{print "   " $$3, $$4, "-", $$6}'
	@echo ""
	@echo "✅ Backup verification complete - safe to proceed with recovery"

recover-volumes: ## 🔄 Recover Released PVs after Longhorn System Restore
	@echo "Recovering Released PersistentVolumes..."
	@echo "This will rebind orphaned volumes after Longhorn System Restore"
	@echo ""
	$(ANSIBLE_PLAYBOOK) playbooks/k8s/recover-volumes.yml

lint-apps: ## 📋 Lint and validate all app configurations
	@echo "=== Linting YAML Files ==="
	@find apps/ -name 'values*.yml' -type f ! -path 'apps/_common/*' | while read file; do \
		echo "Checking $$file..."; \
		uv run yamllint -d relaxed "$$file" || exit 1; \
	done
	@echo ""
	@echo "=== Validating Helm Chart Templates ==="
	@find apps/*/Chart.yml -type f | while read chartfile; do \
		dir=$$(dirname $$chartfile); \
		appname=$$(basename $$dir); \
		if [ -f "$$dir/values.yml" ]; then \
			repo=$$(grep '^chart_repository:' $$chartfile | awk '{print $$2}'); \
			chart=$$(grep '^chart_name:' $$chartfile | awk '{print $$2}'); \
			version=$$(grep '^chart_version:' $$chartfile | awk '{print $$2}'); \
			echo ""; \
			echo "--- Rendering $$appname ($$repo/$$chart:$$version) ---"; \
			uv run helm template $$appname $$repo/$$chart --version $$version -f $$dir/values.yml || exit 1; \
		fi \
	done
	@echo ""
	@echo "✅ All apps validated successfully"

app-deploy: ## 🚀 Deploy specific app (usage: make app-deploy APP=cert-manager)
	@if [ -z "$(APP)" ]; then \
		echo "Error: APP parameter required. Usage: make app-deploy APP=<app-name>"; \
		echo "Available apps:"; \
		ls -1 apps/ | grep -v "^_common$$" | grep -v "README.md"; \
		exit 1; \
	fi
	@if [ ! -d "apps/$(APP)" ]; then \
		echo "Error: App '$(APP)' not found in apps/ directory"; \
		exit 1; \
	fi
	@echo "Deploying $(APP)..."
	$(ANSIBLE_PLAYBOOK) apps/$(APP)/app.yml --diff

app-upgrade: ## 🔄 Upgrade specific app (usage: make app-upgrade APP=cert-manager)
	@if [ -z "$(APP)" ]; then \
		echo "Error: APP parameter required. Usage: make app-upgrade APP=<app-name>"; \
		exit 1; \
	fi
	@echo "Upgrading $(APP)..."
	$(ANSIBLE_PLAYBOOK) apps/$(APP)/app.yml --diff -e upgrade_mode=true

app-list: ## 📦 List all deployed Helm releases
	@echo "Deployed applications:"
	@uv run helm list --all-namespaces || \
		(echo "Note: Run this command on a control plane node" && exit 1)

app-status: ## 📊 Show status of specific app (usage: make app-status APP=demo-app)
	@if [ -z "$(APP)" ]; then \
		echo "Error: APP parameter required. Usage: make app-status APP=<app-name>"; \
		exit 1; \
	fi
	@if [ ! -f "apps/$(APP)/Chart.yml" ]; then \
		echo "Error: Chart.yml not found for $(APP)"; \
		exit 1; \
	fi
	@namespace=$$(grep '^namespace:' apps/$(APP)/Chart.yml | awk '{print $$2}'); \
	release=$$(grep '^release_name:' apps/$(APP)/Chart.yml | awk '{print $$2}'); \
	echo "Status of $(APP):"; \
	echo ""; \
	echo "Helm Release:"; \
	uv run ansible pi-cm5-1 -a "helm status $$release -n $$namespace" --become || true; \
	echo ""; \
	echo "Pods:"; \
	uv run ansible pi-cm5-1 -a "kubectl get pods -n $$namespace -l app.kubernetes.io/instance=$$release" --become || true

app-delete: ## 🗑️  Delete specific app and all resources (usage: make app-delete APP=postgres-test)
	@if [ -z "$(APP)" ]; then \
		echo "Error: APP parameter required. Usage: make app-delete APP=<app-name>"; \
		exit 1; \
	fi
	@if [ ! -f "apps/$(APP)/Chart.yml" ]; then \
		echo "Error: Chart.yml not found for $(APP)"; \
		exit 1; \
	fi
	@namespace=$$(grep '^namespace:' apps/$(APP)/Chart.yml | awk '{print $$2}'); \
	release=$$(grep '^release_name:' apps/$(APP)/Chart.yml | awk '{print $$2}'); \
	echo "⚠️  WARNING: This will delete $(APP) and all its resources"; \
	echo "  - Helm release: $$release"; \
	echo "  - Namespace: $$namespace"; \
	echo "  - PVCs and data will be deleted"; \
	echo ""; \
	read -p "Are you sure? (yes/no): " answer && [ "$$answer" = "yes" ] || (echo "Cancelled." && exit 1); \
	echo ""; \
	echo "Deleting Helm release..."; \
	uv run ansible pi-cm5-1 -a "helm uninstall $$release -n $$namespace" --become || true; \
	echo ""; \
	echo "Removing finalizers from stuck resources..."; \
	uv run ansible pi-cm5-1 -a "kubectl patch pvc -n $$namespace --all -p '{\"metadata\":{\"finalizers\":null}}' --type=merge" --become || true; \
	echo ""; \
	echo "Deleting namespace..."; \
	uv run ansible pi-cm5-1 -a "kubectl delete namespace $$namespace --force --grace-period=0" --become || true; \
	echo ""; \
	echo "✅ App deleted successfully"

apps-deploy-all: ## 🚀 Deploy all apps in apps/ directory
	@echo "Discovering apps in apps/ directory..."
	@apps=$$(ls -1 apps/ | grep -v "^_common$$" | grep -v "README.md"); \
	count=$$(echo "$$apps" | wc -l); \
	echo "Found $$count app(s) to deploy"; \
	echo ""; \
	for app in $$apps; do \
		if [ -f "apps/$$app/app.yml" ]; then \
			echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
			echo "Deploying $$app..."; \
			echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
			$(ANSIBLE_PLAYBOOK) apps/$$app/app.yml --diff || exit 1; \
			echo ""; \
		fi \
	done; \
	echo "✅ All apps deployed successfully"

teardown-check: ## 🔍 Preview infrastructure teardown (dry-run with diff)
	@echo "⚠️ PREVIEW: Infrastructure Teardown (dry-run)"
	@echo "This will show what would be removed:"
	@echo "• K3s cluster from all control plane nodes"
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
	@echo "• K3s cluster from all control plane nodes (pi-cm5-1, pi-cm5-2, pi-cm5-3)"
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
	@echo "Phase 1: Uninstalling K3s cluster..."
	$(ANSIBLE_PLAYBOOK) playbooks/k3s-uninstall.yml
	@echo ""
	@echo "Phase 2: Uninstalling MinIO and certificates..."
	$(ANSIBLE_PLAYBOOK) playbooks/minio-uninstall.yml
	@echo ""
	@echo "🏁 Infrastructure teardown complete!"
	@echo "Base Pi configurations preserved. Ready for fresh deployment with 'make site'"
