# Home Lab Automation

Ansible-based automation for a Raspberry Pi CM5 cluster running K3s Kubernetes.

## What This Does

- Provisions Pi CM5 control plane nodes (K3s cluster)

## Infrastructure

| Node | Role | Description |
|------|------|-------------|
| pi-cm5-1, pi-cm5-2, pi-cm5-3 | Control Plane | K3s masters |
| pi-cm5-4 | Claw | AI |

## Bootstrapping a Fresh Host

Fresh Debian installs don't include `sudo`, so Ansible's privilege escalation fails on first run. SSH in as root and install it before running any playbook:

```bash
ssh root@<hostname>
apt install -y sudo
usermod -aG sudo alexanderp
```

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

## FAQ

### Storage playbook fails with "No key available with this passphrase"

The drives still have LUKS headers from a previous setup. Ansible's
`luks_device state: present` is idempotent — it detects an existing LUKS
header and skips creation, then the open fails because the old key doesn't
match the one in the vault.

Fix: wipe the stale LUKS headers so the playbook can re-encrypt from scratch.

```bash
ssh alexanderp@beelink
sudo wipefs -a /dev/disk/by-id/<drive1>
sudo wipefs -a /dev/disk/by-id/<drive2>
sudo wipefs -a /dev/disk/by-id/<drive3>
```

Drive IDs are listed in `host_vars/beelink/main.yml` under `storage_drives`.
After wiping, re-run the storage playbook and it will create fresh LUKS
containers with the current vault key.

## Common Commands

```bash
make help       # List all commands
make precommit  # Run linters manually (auto-runs on git commit after make setup)
make ping       # Test node connectivity
```
