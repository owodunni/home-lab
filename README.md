# Home Lab Automation

Ansible-based automation for a Raspberry Pi CM5 cluster running K3s Kubernetes.

## What This Does

- Provisions Pi CM5 control plane nodes (K3s cluster)

## Infrastructure

| Node | Role | Description |
|------|------|-------------|
| pi-cm5-1, pi-cm5-2, pi-cm5-3 | Control Plane | K3s masters |
| pi-cm5-4 | Claw | AI |

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

## Common Commands

```bash
make help       # List all commands
make precommit  # Run linters (yamllint, ansible-lint)
make ping       # Test node connectivity
```
