# NFS Migration Notes

This document describes the migration from Longhorn distributed storage to NFS-based storage.

## What Was Removed

### Longhorn Components
- Longhorn distributed storage system
- `apps/longhorn/` Helm chart and configuration
- `longhorn-system` namespace

### Removed Documentation
- `docs/longhorn-disaster-recovery.md` - Longhorn-specific backup procedures
- `docs/longhorn-snapshot-cleanup-explained.md` - Snapshot management guide
- `docs/complete-disaster-recovery-guide.md` - Longhorn-centric recovery guide
- `docs/beelink-storage-setup.md` - LVM/Longhorn storage configuration

### Removed Playbooks
- `playbooks/beelink/02-storage-config.yml` - LVM volume setup for Longhorn
- `playbooks/k8s/migrate-media-to-nfs.yml` - Migration utilities
- `playbooks/k8s/recover-volumes.yml` - Longhorn volume recovery

### Removed MinIO Configuration
- `longhorn-backups` bucket
- `longhorn-backup` user and service account
- Longhorn S3 backup credentials

---

## Current Storage Architecture

### Overview

```
Beelink (6TB NVMe via MergerFS):
├── /mnt/disk1, /mnt/disk2 (LUKS encrypted, ext4)
├── /mnt/parity1 (LUKS encrypted, SnapRAID parity)
└── /mnt/storage (MergerFS pool)
    ├── k8s-apps/     → App config directories
    └── media/        → Media library and torrents

MinIO NAS (2TB HDD via MergerFS):
├── /mnt/minio-disk1 (data)
├── /mnt/minio-parity1 (SnapRAID parity)
└── /mnt/minio-storage (MergerFS pool)
    └── restic-backups bucket
```

### Storage Providers

| Storage Type | Provider | Use Case |
|--------------|----------|----------|
| NFS (default) | nfs-subdir-external-provisioner | Apps on control plane nodes |
| hostPath | Direct mount | Media apps on Beelink |

### Backup System

- **Tool**: restic
- **Target**: MinIO S3 (`restic-backups` bucket)
- **Schedule**: Daily at 3 AM
- **Retention**: 7 daily, 4 weekly, 6 monthly
- **Backed Up**:
  - `/mnt/storage/k8s-apps` (app configurations)
  - `/mnt/storage/media` (media library)

---

## Recovery Capabilities Now Available

### What Works

1. **restic restore from MinIO S3**
   ```bash
   # List available snapshots
   ssh beelink "restic snapshots"

   # Restore latest k8s-apps
   ssh beelink "restic restore latest --target /mnt/storage/k8s-apps --path /mnt/storage/k8s-apps"

   # Restore latest media
   ssh beelink "restic restore latest --target /mnt/storage/media --path /mnt/storage/media"
   ```

2. **SnapRAID parity recovery**
   ```bash
   # Check array status
   ssh beelink "snapraid status"

   # Recover from parity (single disk failure)
   ssh beelink "snapraid fix"
   ```

3. **Full cluster rebuild**
   ```bash
   # 1. Rebuild K3s cluster
   make k3s-cluster

   # 2. Deploy storage provisioner
   make app-deploy APP=nfs-storage

   # 3. Restore data from restic
   ssh beelink "restic restore latest --target /mnt/storage"

   # 4. Redeploy all apps
   make apps-deploy-all
   ```

---

## Recovery Capabilities Lost

### No Longer Available

| Capability | Description |
|------------|-------------|
| Volume snapshots | Longhorn provided instant, space-efficient snapshots via UI |
| Point-in-time recovery | Could restore to any snapshot moment |
| Built-in backup scheduling | Longhorn scheduled S3 backups automatically |
| Volume replication | Data replicated across nodes for HA |
| Web UI management | Longhorn dashboard for volume operations |

### Mitigation

- **Snapshots**: Use restic snapshots instead (daily granularity vs instant)
- **Point-in-time**: restic provides snapshot-based recovery (24h RPO)
- **Backup scheduling**: systemd timers handle backup automation
- **Replication**: SnapRAID parity protects against single disk failure
- **Management**: Direct SSH access to storage nodes

---

## New Recovery Process

### Single App Recovery

```bash
# 1. Scale down the app
kubectl scale deployment -n media radarr --replicas=0

# 2. Restore config from restic
ssh beelink "restic restore latest --target /mnt/storage/k8s-apps/radarr-config --path /mnt/storage/k8s-apps/radarr-config"

# 3. Scale up the app
kubectl scale deployment -n media radarr --replicas=1
```

### Full Disaster Recovery

```bash
# 1. Fresh K3s installation
make k3s-cluster

# 2. Deploy core infrastructure
make app-deploy APP=cert-manager
make app-deploy APP=nfs-storage

# 3. Restore all data from restic
ssh beelink "restic restore latest --target /mnt/storage"

# 4. Redeploy all applications
make apps-deploy-all

# 5. Verify recovery
kubectl get pods --all-namespaces
```

### Recovery Time Objectives

| Scenario | RTO | RPO |
|----------|-----|-----|
| Single app config | 10 min | 24 hours |
| Full cluster rebuild | 2 hours | 24 hours |
| Disk failure (SnapRAID) | 4-8 hours | Minutes |

---

## Migration Rationale

### Why We Migrated

1. **Simplicity**: NFS + hostPath is simpler than distributed storage
2. **Performance**: Direct filesystem access faster for media workloads
3. **Reliability**: Fewer moving parts = fewer failure modes
4. **Resource usage**: No Longhorn pods consuming cluster resources
5. **Direct access**: SSH directly to files for debugging/maintenance

### Trade-offs Accepted

- Lost instant snapshots (acceptable: daily backups sufficient)
- Lost web UI (acceptable: CLI tools adequate)
- Lost volume replication (acceptable: SnapRAID parity sufficient)
- Increased RPO from minutes to 24 hours (acceptable for home lab)

---

## References

- [Storage Architecture](storage-architecture.md) - Current storage design
- [Disaster Recovery](disaster-recovery.md) - Recovery procedures
- [restic documentation](https://restic.readthedocs.io/) - Backup tool docs
- [SnapRAID documentation](https://www.snapraid.it/manual) - Parity protection
