# Home Lab Automation

Ansible-based automation for a Raspberry Pi CM5 cluster running K3s Kubernetes.

## What This Does

- Provisions Pi CM5 control plane nodes (K3s cluster)
- Manages Beelink worker with NFS storage backend
- Deploys applications via Helm (monitoring, media stack, backups)
- Handles secrets with Ansible Vault
- Automates disaster recovery with restic backups to MinIO

## Infrastructure

| Node | Role | Description |
|------|------|-------------|
| pi-cm5-1, pi-cm5-2, pi-cm5-3 | Control Plane | K3s masters |
| beelink | Worker | Compute node |
| pi-cm5-4 | NAS | MergerFS + SnapRAID storage |

## Prerequisites

- **UV Package Manager**: [Install UV](https://docs.astral.sh/uv/getting-started/installation/)
- **SSH access** to all nodes

## Quick Start

1. **Install dependencies:**

   ```bash
   make setup
   ```

2. **Copy SSH keys to nodes:**

   ```bash
   for host in pi-cm5-1 pi-cm5-2 pi-cm5-3 pi-cm5-4 beelink; do
     ssh-copy-id -i ~/.ssh/your_key.pub alexanderp@$host
   done
   ```

3. **Verify connectivity:**

   ```bash
   make ping
   ```

4. **View available commands:**

   ```bash
   make help
   ```

## Documentation

- [Documentation Index](docs/INDEX.md) - All docs organized by topic
- [CLAUDE.md](CLAUDE.md) - AI assistant guidelines

### Key Guides

- [Project Structure](docs/project-structure.md) - Architecture overview
- [App Deployment](docs/app-deployment-guide.md) - Deploy apps to K3s
- [Ansible Vault](docs/ansible-vault.md) - Secrets management
- [Disaster Recovery](docs/disaster-recovery.md) - Backup & restore

## Common Commands

```bash
make help       # List all commands
make precommit  # Run linters (yamllint, ansible-lint)
make ping       # Test node connectivity
```

## Development

1. Install dependencies with `make setup`
2. Write/modify playbooks following [playbook guidelines](docs/playbook-guidelines.md)
3. Run `make precommit` before committing
4. Follow [commit guidelines](docs/git-commit-guidelines.md)
