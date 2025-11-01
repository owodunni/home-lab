# Home Lab Project Structure

This document describes the organization and architecture of the home lab automation repository using Ansible to manage a cluster of Raspberry Pi CM5 devices.

## Directory Structure

```
home-lab/
├── ansible.cfg                 # Ansible configuration
├── hosts.ini                   # Inventory file defining cluster topology
├── requirements.yml            # External Ansible collections/roles
├── CLAUDE.md                   # AI assistant guidance
├── Makefile                    # Development and deployment commands
├── pyproject.toml              # Python dependencies (UV package manager)
├── uv.lock                     # Lock file for dependencies
├── README.md                   # Project overview
├── docs/                       # Documentation
│   ├── project-structure.md    # This file
│   ├── git-commit-guidelines.md
│   ├── playbook-guidelines.md
│   └── beelink-storage-setup.md # Beelink storage configuration guide
├── playbooks/                  # Ansible playbooks
│   ├── beelink-setup.yml       # Initial beelink setup (passwordless sudo)
│   ├── beelink-storage-config.yml # Beelink LUKS+LVM storage configuration
│   ├── upgrade.yml             # System upgrade playbook
│   ├── unattended-upgrades.yml # Unattended upgrades setup
│   ├── pi-base-config.yml      # Pi CM5 base settings and power optimization
│   └── pi-storage-config.yml   # Pi CM5 storage and PCIe configuration
├── roles/                      # Custom Ansible roles
│   └── pi_cm5_config/          # Pi CM5 configuration role
└── group_vars/                 # Variable configuration
    ├── all.yml                 # Variables for all hosts
    ├── all/                    # All hosts directory structure
    │   └── vault.yml           # Encrypted variables for all hosts
    ├── cluster/                # Cluster-specific directory structure
    │   └── k3s.yml            # K3s cluster configuration variables
    ├── nas/                    # NAS-specific directory structure
    │   └── main.yml            # NAS-specific variables
    └── beelink_nas/            # Beelink storage server directory
        ├── main.yml            # Beelink storage configuration
        ├── vault.yml           # Encrypted vault variables
        └── luks.key            # LUKS encryption key (ansible-vault encrypted)
```

## Infrastructure Overview

### Host Groups
- **cluster**: Pi CM5 computing nodes (pi-cm5-1, pi-cm5-2, pi-cm5-3)
- **nas**: MinIO storage server (pi-cm5-4)
- **beelink_nas**: Beelink storage server (beelink)
- **k3s_cluster**: K3s cluster nodes (masters + workers)
  - **masters**: Control plane nodes (pi-cm5-1, pi-cm5-2, pi-cm5-3)
  - **workers**: Dedicated worker nodes (beelink)
- **all**: All devices in the infrastructure

### Network Architecture

**Raspberry Pi CM5 Nodes:**
- K3s Control Plane: pi-cm5-1, pi-cm5-2, pi-cm5-3 (3-node HA with embedded etcd)
- MinIO NAS: pi-cm5-4 (M.2 SATA drives, S3-compatible backup storage)

**Beelink Storage Server:**
- K3s Worker: beelink (Intel N150, 6TB LUKS-encrypted storage for Longhorn)

All devices managed via SSH with user `alexanderp`.

## Ansible Variables System

### Variable Precedence (Highest to Lowest)
1. **Command line** (`-e var=value`)
2. **host_vars/hostname.yml** (host-specific variables)
3. **group_vars/groupname.yml** (group-specific variables)
4. **group_vars/all.yml** (variables for all hosts)
5. **Role defaults** (defined in roles)

### Variable Categories

#### Configuration Variables
Variables that control behavior and should be customizable:
```yaml
# Good examples
unattended_automatic_reboot: true
unattended_automatic_reboot_time: "03:00"
backup_retention_days: 30
monitoring_enabled: true
```

#### Infrastructure Variables
Variables that describe the environment:
```yaml
# Good examples
cluster_nodes:
  - pi-cm5-1
  - pi-cm5-2
  - pi-cm5-3
nas_storage_path: "/mnt/storage"
network_domain: "homelab.local"
```

#### Avoid Hardcoding
- File paths that might change
- Service ports that might conflict
- Credentials (use Ansible Vault)
- Environment-specific values

### group_vars Usage Patterns

#### group_vars/all.yml
Unified configuration for all hosts:
```yaml
---
# Unattended upgrades configuration for all Pi cluster hosts
unattended_origins_patterns:
  - 'origin=Debian,codename=${distro_codename},label=Debian-Security'
  - 'origin=Debian,codename=${distro_codename},label=Debian'
  - 'origin=Raspbian,codename=${distro_codename},label=Raspbian'

unattended_automatic_reboot: true
unattended_automatic_reboot_time: "02:00"

# Pi CM5 configuration - modular approach with focused playbooks
pi_basic_config:
  arm_64bit: 1
  gpu_mem: 64  # Minimal for headless operation
  camera_auto_detect: 0
  display_auto_detect: 0

pi_power_optimize:
  disable_wifi: true      # ~183mW power reduction
  disable_bluetooth: true
  disable_hdmi_audio: true
  disable_leds: true      # <2mA per LED
```

#### group_vars/cluster.yml and group_vars/nas.yml
Group-specific configurations for different hardware requirements:
```yaml
# group_vars/cluster.yml - Compute nodes without M.2 storage
pi_storage_config:
  pcie:
    enabled: false  # Disable PCIe for power savings

# group_vars/nas.yml - Storage node with M.2 SATA controller
pi_storage_config:
  pcie:
    enabled: true   # Enable PCIe for M.2 SATA support
```

#### group_vars/beelink_nas/main.yml
Beelink storage server configuration with LUKS-encrypted LVM:
```yaml
# Hardware-specific storage configuration
longhorn_storage_drives:
  - device: /dev/disk/by-id/nvme-CT2000P310SSD8_24454C177944
    label: LONGHORN1
  # Additional drives...

# LUKS encryption configuration
luks_key_file: "{{ inventory_dir }}/group_vars/beelink_nas/luks.key"
luks_crypt_devices:
  - name: longhorn1_crypt
    device: "{{ longhorn_storage_drives[0].device }}"

# LVM configuration
lvm_volume_group: longhorn-vg
lvm_logical_volume: longhorn-lv
lvm_volume_size: 100%FREE

# Filesystem and mount configuration
longhorn_filesystem: ext4
longhorn_mount_point: /var/lib/longhorn
longhorn_mount_options: "defaults,noatime"
```

**Key differences from Pi NAS:**
- Uses LUKS encryption for data-at-rest security
- Aggregates all drives with LVM (vs individual mounts)
- ext4 filesystem (Longhorn recommended)
- Single mount point for all storage

#### host_vars/ (When to Use)
Create `host_vars/hostname.yml` only for truly unique per-host settings:
```yaml
---
# host_vars/pi-cm5-1.yml (example)
cluster_role: primary
```

## Configuration Strategy

### Environment-Specific Settings
Use group_vars for different environment behaviors:
- **Development**: Aggressive updates, verbose logging
- **Production**: Conservative updates, minimal reboots

### Security Considerations
- Use Ansible Vault for secrets
- Limit update sources to security repositories
- Configure appropriate reboot windows
- Test changes in staging before production

### Scalability Guidelines
- Add new host groups in `hosts.ini`
- Create corresponding `group_vars/newgroup.yml`
- Update playbooks to target appropriate groups
- Maintain variable inheritance hierarchy

## Best Practices

### Variable Naming
- Use descriptive prefixes: `unattended_`, `backup_`, `monitoring_`
- Boolean variables: `enabled`/`disabled` suffix
- Time values: Include units (`_seconds`, `_minutes`)

### File Organization
- One concern per playbook
- Group related variables together
- Comment complex variable structures
- Use consistent YAML formatting

### Documentation
- Document variable purposes in group_vars files
- Explain non-obvious playbook behavior
- Keep this structure document updated
- Reference external role documentation
