# Disaster Recovery Guide

This document covers disaster recovery procedures for NFS-based storage architecture.

## Table of Contents

- [Overview](#overview)
- [Backup Architecture](#backup-architecture)
- [Recovery Scenarios](#recovery-scenarios)
  - [Scenario 1: Single File Restore (restic)](#scenario-1-single-file-restore-restic)
  - [Scenario 2: Full Media Library Restore](#scenario-2-full-media-library-restore)
  - [Scenario 3: Beelink Disk Failure (SnapRAID)](#scenario-3-beelink-disk-failure-snapraid)
  - [Scenario 4: MinIO Disk Failure](#scenario-4-minio-disk-failure)
  - [Scenario 5: Complete Cluster Rebuild](#scenario-5-complete-cluster-rebuild)
- [Recovery Time Objectives](#recovery-time-objectives)
- [Verification Procedures](#verification-procedures)

## Overview

The home lab uses a **unified backup strategy** with restic:

| Storage Type | Backup Method | Target | Schedule | Retention |
|--------------|---------------|--------|----------|-----------|
| **k8s-apps volumes** | restic (incremental, deduplicated) | MinIO S3 (restic-backups) | Daily 3 AM | 7 daily, 4 weekly, 6 monthly |
| **NFS media volumes** | restic (incremental, deduplicated) | MinIO S3 (restic-backups) | Daily 3 AM | 7 daily, 4 weekly, 6 monthly |
| **SnapRAID parity** (Beelink) | Parity sync | Local `/mnt/parity1` | Daily 4 AM | N/A (parity data) |
| **SnapRAID parity** (MinIO) | Parity sync | Local `/mnt/minio-parity1` | Daily 5 AM | N/A (parity data) |

## Backup Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ BEELINK (NFS Storage)                                          │
│                                                                │
│  /mnt/storage/k8s-apps (app configs)                          │
│  /mnt/storage/media (media files)                             │
│       ↓                                                         │
│  restic backup (3 AM)                                          │
│       ↓                                                         │
│  s3://minio/restic-backups/                                    │
│       ↓                                                         │
│  SnapRAID sync (4 AM)                                          │
│       ↓                                                         │
│  Local parity: /mnt/parity1                                    │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ MINIO NAS (Backup Target)                                     │
│                                                                │
│  /mnt/minio-storage (1TB, MergerFS + SnapRAID)                │
│       ↓                                                         │
│  SnapRAID sync (5 AM)                                          │
│       ↓                                                         │
│  Local parity: /mnt/minio-parity1                              │
└────────────────────────────────────────────────────────────────┘
```

## Recovery Scenarios

### Scenario 1: Single File Restore (restic)

**Use case**: Accidentally deleted movie, need to restore from backup

**Recovery time**: 1-5 minutes

**Steps**:

1. List available snapshots:
   ```bash
   ssh beelink
   export RESTIC_PASSWORD_FILE=/root/.restic-password
   export AWS_ACCESS_KEY_ID={{ vault_restic_s3_access_key }}
   export AWS_SECRET_ACCESS_KEY={{ vault_restic_s3_secret_key }}

   restic -r s3:https://minio.jardoole.xyz/restic-backups snapshots
   ```

2. Find the file in a snapshot:
   ```bash
   restic -r s3:https://minio.jardoole.xyz/restic-backups ls latest \
     | grep "MovieName.mkv"
   ```

3. Restore specific file:
   ```bash
   restic -r s3:https://minio.jardoole.xyz/restic-backups restore latest \
     --target /mnt/storage/media \
     --include /media/library/movies/MovieName.mkv
   ```

4. Verify restoration:
   ```bash
   ls -lh /mnt/storage/media/library/movies/MovieName.mkv
   ```

### Scenario 2: Full Media Library Restore

**Use case**: Complete data loss on Beelink, need to restore entire media library

**Recovery time**: 2-6 hours (depending on data size and network speed)

**Steps**:

1. Ensure MergerFS and SnapRAID are configured (see Phase 1 implementation)

2. List available snapshots:
   ```bash
   ssh beelink
   export RESTIC_PASSWORD_FILE=/root/.restic-password
   export AWS_ACCESS_KEY_ID={{ vault_restic_s3_access_key }}
   export AWS_SECRET_ACCESS_KEY={{ vault_restic_s3_secret_key }}

   restic -r s3:https://minio.jardoole.xyz/restic-backups snapshots
   ```

3. Restore entire media directory:
   ```bash
   # Restore to temporary location first
   restic -r s3:https://minio.jardoole.xyz/restic-backups restore latest \
     --target /tmp/restore

   # Verify restoration
   du -sh /tmp/restore/media

   # Move to production location
   rsync -avh --progress /tmp/restore/media/ /mnt/storage/media/
   ```

4. Rebuild SnapRAID parity:
   ```bash
   snapraid sync
   ```

5. Verify K3s pods can access data:
   ```bash
   kubectl exec -n media deployment/jellyfin -- ls /media/library/movies
   ```

**Alternative: Restore from specific date**:
```bash
# List snapshots with dates
restic -r s3:https://minio.jardoole.xyz/restic-backups snapshots

# Restore from specific snapshot ID
restic -r s3:https://minio.jardoole.xyz/restic-backups restore abc123 \
  --target /mnt/storage/media
```

### Scenario 3: Beelink Disk Failure (SnapRAID)

**Use case**: Data drive failed, recover using SnapRAID parity

**Recovery time**: 1-3 hours (depending on drive size)

**Steps**:

1. Identify failed drive:
   ```bash
   ssh beelink
   snapraid status
   # Shows which drive has errors
   ```

2. Replace failed drive (if hardware failure):
   ```bash
   # Physically replace drive
   # Format new drive
   cryptsetup luksFormat /dev/nvme1n1 --key-file /root/.luks/beelink-luks.key
   cryptsetup open /dev/nvme1n1 disk2_crypt --key-file /root/.luks/beelink-luks.key
   mkfs.ext4 -L disk2 /dev/mapper/disk2_crypt
   mount /dev/mapper/disk2_crypt /mnt/disk2
   ```

3. Recover data from parity:
   ```bash
   # Fix all files on failed drive
   snapraid fix -d disk2

   # Verify fix
   snapraid status
   ```

4. Rebuild parity:
   ```bash
   snapraid sync
   ```

5. Verify MergerFS pool:
   ```bash
   df -h /mnt/storage
   ls /mnt/storage/media
   ```

**If parity drive fails** (no data loss, but no redundancy):
```bash
# Replace parity drive
mkfs.ext4 -L parity1 /dev/mapper/parity1_crypt
mount /dev/mapper/parity1_crypt /mnt/parity1

# Rebuild parity from scratch
snapraid sync
```

### Scenario 4: MinIO Disk Failure

**Use case**: MinIO data drive failed, recover using SnapRAID parity

**Recovery time**: 30 minutes - 1 hour

**Steps**:

1. Identify failed drive:
   ```bash
   ssh pi-cm5-4
   snapraid status
   ```

2. Replace failed drive:
   ```bash
   # Format new drive
   mkfs.xfs -L minio-disk1 /dev/sdc
   mount /dev/sdc /mnt/minio-disk1
   ```

3. Recover data from parity:
   ```bash
   snapraid fix -d d1
   snapraid status
   ```

4. Rebuild parity:
   ```bash
   snapraid sync
   ```

5. Verify MinIO accessible:
   ```bash
   systemctl status minio
   curl -I https://minio.jardoole.xyz
   ```

### Scenario 5: Complete Cluster Rebuild

**Use case**: Total cluster failure, rebuild from scratch

**Recovery time**: 3-4 hours

**Steps**:

#### Phase 1: Rebuild Infrastructure (1 hour)

1. Ensure physical hosts are accessible:
   ```bash
   ansible all -m ping
   ```

2. Reconfigure Beelink storage:
   ```bash
   make beelink-storage-reconfigure
   ```

3. Reconfigure MinIO storage:
   ```bash
   make minio-storage-reconfigure
   ```

4. Rebuild K3s cluster:
   ```bash
   make k3s-teardown
   make k3s
   ```

#### Phase 2: Restore Data (2-3 hours)

1. Restore k8s-apps and media from restic:
   ```bash
   ssh beelink
   restic -r s3:https://minio.jardoole.xyz/restic-backups restore latest \
     --target /mnt/storage
   ```

2. Rebuild SnapRAID parity:
   ```bash
   snapraid sync
   ```

#### Phase 3: Redeploy Applications (30 minutes)

1. Deploy NFS provisioner:
   ```bash
   make app-deploy APP=nfs-storage
   ```

2. Deploy media stack:
   ```bash
   make app-deploy APP=media-stack
   ```

3. Verify all apps running:
   ```bash
   kubectl get pods -n media
   kubectl get pvc -n media
   ```

#### Phase 4: Validation

1. Test hardlinks:
   ```bash
   kubectl exec -n media deployment/radarr -- \
     sh -c 'touch /data/torrents/test && ln /data/torrents/test /data/library/test'
   kubectl exec -n media deployment/radarr -- stat /data/library/test
   # Should show Links: 2
   ```

2. Test SSH access:
   ```bash
   ssh beelink "ls /mnt/storage/media/library/movies"
   ```

3. Test backups:
   ```bash
   ssh beelink "/usr/local/bin/backup-media.sh"
   restic -r s3:https://minio.jardoole.xyz/restic-backups snapshots
   ```

## Recovery Time Objectives

| Scenario | RTO (Recovery Time) | RPO (Recovery Point) | Data Loss Risk |
|----------|---------------------|----------------------|----------------|
| Single file restore | 1-5 minutes | 24 hours (daily backup) | Minimal |
| Full media restore | 2-6 hours | 24 hours | Minimal |
| Beelink disk failure | 1-3 hours | None (parity recovery) | None if parity valid |
| MinIO disk failure | 30 min - 1 hour | None (parity recovery) | None if parity valid |
| Complete cluster rebuild | 2-3 hours | 24 hours | Minimal |

**Key assumptions**:
- restic backups running daily at 3 AM (k8s-apps + media)
- SnapRAID parity synced daily (4 AM Beelink, 5 AM MinIO)
- MinIO S3 storage accessible

## Verification Procedures

### Daily Backup Verification

**Automated checks** (add to cron or monitoring):

```bash
#!/bin/bash
# /usr/local/bin/verify-backups.sh

# Check restic backup status
echo "=== restic Backup Status ==="
restic -r s3:https://minio.jardoole.xyz/restic-backups snapshots --last
if [ $? -ne 0 ]; then
  echo "ERROR: restic backup check failed"
  exit 1
fi

# Check SnapRAID status
echo "=== SnapRAID Status ==="
snapraid status
if [ $? -ne 0 ]; then
  echo "ERROR: SnapRAID status check failed"
  exit 1
fi

echo "All backup checks passed!"
```

### Monthly Integrity Checks

**restic repository check**:
```bash
# Full repository check (reads all data)
restic -r s3:https://minio.jardoole.xyz/restic-backups check --read-data

# Verify specific snapshot
restic -r s3:https://minio.jardoole.xyz/restic-backups check --read-data-subset=10%
```

**SnapRAID scrub** (verify parity integrity):
```bash
# Scrub 10% of data monthly
snapraid scrub -p 10

# Full scrub (quarterly)
snapraid scrub
```

### Restore Testing

**Test restore to temporary location** (quarterly):
```bash
# Restore sample files
restic -r s3:https://minio.jardoole.xyz/restic-backups restore latest \
  --target /tmp/restore-test \
  --include /media/library/movies/ \
  --path-filter "*.mkv" | head -10

# Verify restoration
ls -lh /tmp/restore-test/media/library/movies/
rm -rf /tmp/restore-test
```

## Best Practices

1. **Monitor backup jobs**:
   - Check systemd timer status: `systemctl list-timers`
   - Review backup logs: `journalctl -u backup-media.service`

2. **Test restores regularly**:
   - Monthly: Restore single file
   - Quarterly: Restore full directory to test location
   - Annually: Full disaster recovery drill

3. **Document changes**:
   - Update this guide when adding new volumes
   - Document recovery procedures for custom apps
   - Keep vault passwords secure and accessible offline

4. **Offsite backups** (future enhancement):
   - Replicate MinIO S3 to external cloud storage
   - Use `rclone` to sync backups to Backblaze B2 or AWS S3

## Related Documentation

- [Storage Architecture Guide](storage-architecture.md) - Storage configuration details
- [App Deployment Guide](app-deployment-guide.md) - Application deployment with NFS storage
