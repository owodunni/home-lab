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
│   ├── app-deployment-guide.md # K8s app deployment guide
│   ├── helm-standards.md       # Helm chart standards and conventions
│   ├── git-commit-guidelines.md
│   ├── playbook-guidelines.md
│   └── beelink-storage-setup.md # Beelink storage configuration guide
├── apps/                       # K8s application deployments
│   ├── README.md               # App deployment quick start
│   ├── _common/                # Shared app components
│   │   ├── values/             # Reusable Helm value templates
│   │   │   └── resource-limits.yml  # Resource limit profiles
│   │   └── tasks/              # Reusable Ansible tasks
│   │       └── wait-for-ready.yml   # Deployment readiness checks
│   └── <app-name>/             # Individual app directory
│       ├── Chart.yml           # Helm chart metadata
│       ├── values.yml          # Helm values configuration
│       ├── app.yml             # App deployment playbook
│       ├── prerequisites.yml   # (Optional) Pre-deployment tasks
│       └── README.md           # App-specific documentation
├── playbooks/                  # Ansible playbooks
│   ├── deploy-helm-app.yml     # Reusable Helm app deployment playbook
│   ├── upgrade.yml             # System upgrade playbook
│   ├── unattended-upgrades.yml # Unattended upgrades setup
│   ├── pi-base-config.yml      # Pi CM5 base settings and power optimization
│   ├── pi-storage-config.yml   # Pi CM5 storage and PCIe configuration
│   ├── beelink/                # Beelink-specific playbooks
│   │   ├── 01-initial-setup.yml           # Passwordless sudo setup
│   │   ├── 02-storage-config.yml          # LUKS encryption configuration
│   │   ├── 03-storage-reconfigure-mergerfs.yml # MergerFS + SnapRAID setup
│   │   ├── 04-restic-backup-setup.yml     # Restic backup automation
│   │   ├── 05-snapraid-sync-setup.yml     # SnapRAID sync automation
│   │   └── beelink-complete.yml           # Complete Beelink deployment
│   ├── nas/                    # NAS-specific playbooks
│   │   ├── minio-storage-reconfigure.yml  # MinIO storage MergerFS + SnapRAID
│   │   ├── minio-snapraid-sync-setup.yml  # MinIO SnapRAID automation
│   │   └── minio-disk-spindown-setup.yml  # Disk power management
│   └── k3s/                    # K3s cluster deployment
│       ├── k3s-complete.yml    # Complete K3s deployment orchestrator
│       ├── 01-k3s-cluster.yml  # K3s cluster installation
│       ├── 02-helm-setup.yml   # Helm and plugin installation
│       └── ...                 # Additional K3s phase playbooks
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

## Application Deployment Structure

The `apps/` directory contains standardized Kubernetes application deployments using Helm charts. This structure provides:

- **Consistent deployment patterns** - All apps follow the same structure
- **Reusable components** - Common values and tasks shared across apps
- **Easy app management** - Simple Makefile commands for deployment
- **Version control** - Chart versions and configurations tracked in Git

### App Directory Layout

Each application follows this structure:

```
apps/<app-name>/
├── Chart.yml           # Chart metadata (repo, name, version)
├── values.yml          # Helm values configuration
├── app.yml             # Deployment playbook
├── prerequisites.yml   # (Optional) Pre-deployment setup
└── README.md           # App-specific documentation
```

### Example: cert-manager App

```
apps/cert-manager/
├── Chart.yml           # Defines jetstack/cert-manager v1.13.2
├── values.yml          # Resource limits, node selectors, CRD installation
├── app.yml             # Calls playbooks/deploy-helm-app.yml
└── README.md           # cert-manager deployment notes
```

### Common Components

**apps/_common/values/resource-limits.yml**
Provides reusable YAML anchors for Pi CM5-optimized resource limits:

- `*common-resource-limits-small` - 50m CPU, 64Mi RAM (sidecars, small apps)
- `*common-resource-limits-medium` - 100m CPU, 128Mi RAM (standard apps)
- `*common-resource-limits-large` - 200m CPU, 256Mi RAM (resource-intensive apps)

**apps/_common/tasks/**
Reusable Ansible tasks for app deployment:

- `wait-for-ready.yml` - Wait for deployments to reach ready state

**Validation**: Chart and values validation handled by `make lint-apps` (runs yamllint + helm template) and pre-commit hooks.

### Deployment Workflow

1. **Create app directory** with Chart.yml, values.yml, app.yml
2. **Validate configuration**: `make helm-lint`
3. **Deploy app**: `make app-deploy APP=<name>`
4. **Check status**: `make app-status APP=<name>`

See [App Deployment Guide](app-deployment-guide.md) for complete workflow.

### Helm Chart Standards

All apps follow standardized conventions:

- **Exact version pinning** - No version ranges (`1.13.2` not `~1.13.0`)
- **Resource limits required** - All containers specify requests/limits
- **Consistent naming** - `<app>-tls-secret` for certificates
- **Vault references** - Secrets use `{{ vault_app_secret }}` pattern

See [Helm Standards](helm-standards.md) for complete conventions.

## Infrastructure Overview

### Host Groups
- **cluster**: Pi CM5 control plane nodes (pi-cm5-1, pi-cm5-2, pi-cm5-3)
- **nas**: MinIO storage server (pi-cm5-4)
- **beelink_nas**: Beelink storage server (beelink)
- **k3s_cluster**: K3s cluster nodes (masters + workers)
  - **control_plane**: Control plane nodes (pi-cm5-1, pi-cm5-2, pi-cm5-3)
  - **workers**: Dedicated worker nodes (beelink)
- **all**: All devices in the infrastructure

### Network Architecture

**Raspberry Pi CM5 Nodes:**
- K3s Control Plane: pi-cm5-1, pi-cm5-2, pi-cm5-3 (3-node HA with embedded etcd)
- MinIO NAS: pi-cm5-4 (M.2 SATA drives, S3-compatible backup storage)

**Beelink Storage Server:**
- K3s Worker: beelink (Intel N150, 6TB LUKS-encrypted storage with MergerFS + SnapRAID, NFS exports)

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
# group_vars/cluster.yml - Control plane nodes without M.2 storage
pi_storage_config:
  pcie:
    enabled: false  # Disable PCIe for power savings

# group_vars/nas.yml - Storage node with M.2 SATA controller
pi_storage_config:
  pcie:
    enabled: true   # Enable PCIe for M.2 SATA support
```

#### group_vars/beelink_nas/main.yml
Beelink storage server configuration with MergerFS + SnapRAID:
```yaml
# Hardware-specific storage configuration (3x 2TB NVMe drives)
storage_drives:
  - device: /dev/disk/by-id/nvme-CT2000P310SSD8_24454C177944
    label: disk1
    mount_point: /mnt/disk1
  - device: /dev/disk/by-id/nvme-CT2000P310SSD8_24454C37CB1B
    label: disk2
    mount_point: /mnt/disk2
  - device: /dev/disk/by-id/nvme-CT2000P310SSD8_24454C40D38E
    label: parity1
    mount_point: /mnt/parity1

# LUKS encryption configuration (data-at-rest security)
luks_key_file: "{{ inventory_dir }}/group_vars/beelink_nas/luks.key"
luks_crypt_devices:
  - name: disk1_crypt
    device: "{{ storage_drives[0].device }}"
  - name: disk2_crypt
    device: "{{ storage_drives[1].device }}"
  - name: parity1_crypt
    device: "{{ storage_drives[2].device }}"

# MergerFS configuration (pool data drives)
mergerfs_mount_point: /mnt/storage
mergerfs_data_drives:
  - /mnt/disk1
  - /mnt/disk2
mergerfs_options: "defaults,allow_other,use_ino,cache.files=partial,dropcacheonclose=true,category.create=mfs"

# SnapRAID configuration (parity protection)
snapraid_parity_drives:
  - /mnt/parity1/snapraid.parity
snapraid_data_drives:
  - path: /mnt/disk1
    name: d1
  - path: /mnt/disk2
    name: d2
snapraid_content_files:
  - /var/snapraid.content
  - /mnt/disk1/.snapraid.content
  - /mnt/disk2/.snapraid.content

# NFS export configuration (K3s pod access)
nfs_exports:
  - path: /mnt/storage
    clients: "10.42.0.0/16(rw,sync,no_subtree_check,no_root_squash)"

# Filesystem configuration
storage_filesystem: ext4
storage_mount_options: "defaults,noatime"
```

**Storage architecture:**
- **2 data drives + 1 parity drive** = 4TB usable storage
- **LUKS encryption** for all drives (data-at-rest security)
- **MergerFS** pools data drives into single mount point
- **SnapRAID** provides parity protection (daily sync)
- **NFS server** exports storage to K3s pods
- **Expandable**: Add more drives to increase capacity

#### group_vars/nas/main.yml
MinIO NAS storage configuration with MergerFS + SnapRAID:
```yaml
# SATA HDD configuration (2x 2TB drives)
minio_storage_drives:
  - device: /dev/disk/by-id/wwn-0x5000c5008a1a78df
    label: minio-disk1
    mount_point: /mnt/minio-disk1
  - device: /dev/disk/by-id/wwn-0x5000c5008a1a7d0f
    label: minio-parity1
    mount_point: /mnt/minio-parity1

# MergerFS configuration (pool data drives)
minio_mergerfs_mount: /mnt/minio-storage
minio_mergerfs_data_drives:
  - /mnt/minio-disk1
minio_mergerfs_options: "defaults,allow_other,use_ino,cache.files=partial,dropcacheonclose=true,category.create=mfs"

# SnapRAID configuration (parity protection)
minio_snapraid_parity_drives:
  - /mnt/minio-parity1/snapraid.parity
minio_snapraid_data_drives:
  - path: /mnt/minio-disk1
    name: d1
minio_snapraid_content_files:
  - /var/minio-snapraid.content
  - /mnt/minio-disk1/.snapraid.content

# MinIO service configuration
minio_server_datadirs: "/mnt/minio-storage"
minio_server_port: 9000
minio_console_port: 443
minio_root_user: miniosuperuser
minio_root_password: "{{ vault_minio_root_password }}"

# Filesystem configuration
minio_filesystem: xfs  # Object storage optimized
minio_mount_options: "defaults,noatime"
```

**Storage architecture:**
- **1 data drive + 1 parity drive** = 2TB usable storage (2x 2TB HDDs)
- **No LUKS encryption** (MinIO provides HTTPS encryption in-transit)
- **MergerFS** pools data drives into single mount point
- **SnapRAID** provides parity protection (daily sync at 5 AM)
- **Expandable**: Add more HDDs via SATA or USB to increase capacity
- **S3 backup target** for Longhorn config volumes and restic media backups

#### host_vars/ (When to Use)
Create `host_vars/hostname.yml` only for truly unique per-host settings:
```yaml
---
# host_vars/pi-cm5-1.yml (example)
cluster_role: primary
```

## Storage Architecture Strategy

The infrastructure uses a **hybrid storage approach** that leverages the strengths of both Longhorn distributed storage and filesystem-based NFS storage.

### Storage Type Selection

**Use Longhorn for:**
- **Application configs** (<10GB) - Database settings, metadata, small volumes
- **Database volumes** - PostgreSQL, MySQL, MongoDB data directories
- **Snapshots required** - Volumes needing point-in-time recovery
- **Multi-node access** - Volumes with RWX (ReadWriteMany) requirements
- **Examples**: Radarr config (1Gi), Jellyfin config (10Gi), PostgreSQL data (5Gi)

**Use NFS (filesystem storage) for:**
- **Large media volumes** (>50GB) - Movies, TV shows, photos, videos
- **SSH access needed** - Data requiring manual file management
- **Hardlink support** - Applications requiring same-filesystem hardlinks (media stack)
- **Backup-friendly** - Large datasets needing incremental backups (restic)
- **Examples**: Jellyfin media library (1TB+), Immich photos (500GB+), Nextcloud files (200GB+)

### Why This Hybrid Approach?

**Longhorn strengths:**
- Kubernetes-native (PVC/PV integration)
- Automatic snapshots and backups for small volumes
- Works well for databases and configs (<10GB)
- Disaster recovery tested and working

**Longhorn limitations (discovered through 867GB data loss):**
- Large volumes (>100GB) backup unreliability
- Snapshot chain format makes data inaccessible without Longhorn engine
- Cannot manually access data via SSH (must exec into pods)
- Complex disaster recovery for large volumes

**Filesystem (MergerFS + SnapRAID + NFS) strengths:**
- Direct SSH access to files
- Disk-level redundancy (survive single disk failure)
- Easy expansion (add drives one at a time)
- Incremental backups with restic (deduplication)
- Simple disaster recovery (restic restore)
- Better storage efficiency (parity vs 3x replication)

### Architecture Diagram

```
┌────────────────────────────────────────────────────────────────┐
│ K3s Cluster Storage                                            │
│                                                                │
│  Small Volumes (<10GB)          Large Volumes (>50GB)         │
│  ┌──────────────┐                ┌──────────────┐            │
│  │  Longhorn    │                │  NFS Storage │            │
│  │  (RWO/RWX)   │                │  (RWX)       │            │
│  └──────┬───────┘                └──────┬───────┘            │
│         │                               │                     │
│         │                               │                     │
│    ┌────▼─────────────┐        ┌───────▼──────────┐         │
│    │ Config Volumes:  │        │ Media Volumes:   │         │
│    │ - radarr-config  │        │ - media-stack-nfs│         │
│    │ - sonarr-config  │        │ - nextcloud-data │         │
│    │ - jellyfin-config│        │ - immich-library │         │
│    └──────────────────┘        └──────────────────┘         │
│                                                                │
│  Backed up to MinIO S3 (daily)  Backed up via restic (daily) │
└────────────────────────────────────────────────────────────────┘
```

### Deployment Pattern

See [Storage Architecture Guide](storage-architecture.md) for complete implementation details.

For app deployment examples, see [App Deployment Guide](app-deployment-guide.md#storage-selection).

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
