# Storage Setup Quickstart

Quick reference for setting up the filesystem-based storage architecture using make tasks.

## Overview

The new storage architecture uses:
- **Beelink**: MergerFS + SnapRAID (2 data + 1 parity = 4TB usable)
- **MinIO NAS**: MergerFS + SnapRAID (1 data + 1 parity = 2TB usable)
- **Backups**: restic to MinIO S3 + SnapRAID parity protection
- **K8s Integration**: NFS provisioner for direct filesystem access

## Prerequisites

1. **Vault variables configured** (see playbooks/beelink/VAULT_VARIABLES_NEEDED.md):
   ```bash
   uv run ansible-vault edit group_vars/all/vault.yml
   ```
   Add:
   ```yaml
   # Restic repository encryption password
   vault_restic_password: "your-secure-restic-password"

   # MinIO user password
   vault_restic_backup_password: "your-secure-user-password"

   # S3 service account credentials (choose your own)
   vault_restic_s3_access_key: "restic-s3-access-key-minimum-16-chars"
   vault_restic_s3_secret_key: "restic-s3-secret-key-minimum-16-chars"
   ```

   **Note**: The MinIO user (`restic-backup`), bucket (`restic-backups`), and service account will be created automatically during MinIO setup.

2. **Dependencies installed**:
   ```bash
   make setup
   ```

## Full Infrastructure Setup

To set up everything from scratch:

```bash
make site
```

This runs all phases sequentially:
1. Base Pi CM5 configuration
2. System upgrades
3. Storage configuration
4. Beelink storage (MergerFS + SnapRAID)
5. MinIO storage (MergerFS + SnapRAID)
6. MinIO service
7. Backup automation
8. K3s cluster
9. NFS storage provisioner

## Individual Tasks

If you need to run specific phases:

### Beelink Storage Setup
```bash
make beelink-storage
```
- Configures LUKS + MergerFS + SnapRAID on Beelink
- Creates /mnt/storage (4TB usable)
- Exports via NFS to K8s cluster

### MinIO Storage Setup
```bash
make minio-storage
```
- Configures MergerFS + SnapRAID on MinIO NAS
- Creates /mnt/minio-storage (2TB usable)
- No encryption (MinIO provides HTTPS)

### Backup Automation
```bash
make backup-setup
```
- Configures restic backups to MinIO S3
- Sets up SnapRAID sync timers (Beelink + MinIO)
- Schedule: restic 3 AM, Beelink SnapRAID 4 AM, MinIO SnapRAID 5 AM

### NFS Storage Provisioner
```bash
make app-deploy APP=nfs-storage
```
- Deploys NFS provisioner to K8s
- Creates `nfs-media` storage class
- Enables RWX volumes from Beelink

## Verification

### Check Storage Setup
```bash
# Verify Beelink storage
ssh beelink "df -h /mnt/storage"
ssh beelink "snapraid status"

# Verify MinIO storage
ssh pi-cm5-4 "df -h /mnt/minio-storage"
ssh pi-cm5-4 "snapraid -c /etc/snapraid-minio.conf status"

# Verify NFS export
showmount -e beelink
```

### Check Backup Automation
```bash
# Check systemd timers
ssh beelink "systemctl status backup-media.timer"
ssh beelink "systemctl status snapraid-sync.timer"
ssh pi-cm5-4 "systemctl status minio-snapraid-sync.timer"

# List backup snapshots
ssh beelink "restic -r s3:https://minio.jardoole.xyz:9000/restic-backups snapshots"
```

### Check K8s Integration
```bash
# Verify storage class
kubectl get storageclass nfs-media

# Check NFS provisioner
kubectl get pods -n kube-system -l app=nfs-subdir-external-provisioner
```

## Common Workflows

### Fresh Install (No Data to Preserve)
```bash
# Complete infrastructure setup
make site

# Verify everything is working
kubectl get nodes
kubectl get storageclass
```

### Reset Storage (Destructive)
```bash
# Reconfigure Beelink storage (destroys data)
make beelink-storage

# Reconfigure MinIO storage (destroys data)
make minio-storage

# Reconfigure backup automation
make backup-setup
```

### Add Storage to Existing Cluster
```bash
# If cluster exists but needs new storage architecture
make beelink-storage
make minio-storage
make backup-setup
make app-deploy APP=nfs-storage
```

## Troubleshooting

### Storage not mounting
```bash
# Check LUKS devices
ssh beelink "lsblk"
ssh beelink "cryptsetup status disk1_crypt"

# Check MergerFS mount
ssh beelink "mount | grep mergerfs"
```

### NFS not accessible from pods
```bash
# Check NFS server
ssh beelink "systemctl status nfs-kernel-server"
ssh beelink "exportfs -v"

# Test from pod
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  sh -c "ping -c 3 beelink && mount -t nfs beelink:/mnt/storage /mnt"
```

### Backup not running
```bash
# Check timer status
ssh beelink "systemctl list-timers | grep backup"

# Check logs
ssh beelink "journalctl -u backup-media.service -n 50"

# Manual test
ssh beelink "sudo /usr/local/bin/backup-media.sh"
```

## Related Documentation

- [Storage Architecture Guide](storage-architecture.md) - Complete technical details
- [Disaster Recovery Guide](disaster-recovery.md) - Backup and restore procedures
- [App Deployment Guide](app-deployment-guide.md) - Using storage in applications
- [Project Structure](project-structure.md) - Configuration variable hierarchy
