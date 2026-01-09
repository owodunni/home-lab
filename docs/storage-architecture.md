# Storage Architecture Guide

This document describes the filesystem-based storage architecture using MergerFS + SnapRAID for large volumes, complementing Longhorn for small volumes.

## Table of Contents

- [Overview](#overview)
- [Architecture Comparison](#architecture-comparison)
- [Technology Stack](#technology-stack)
- [Beelink Storage Configuration](#beelink-storage-configuration)
- [MinIO NAS Storage Configuration](#minio-nas-storage-configuration)
- [Backup Strategy](#backup-strategy)
- [Kubernetes Integration](#kubernetes-integration)
- [Expansion Guide](#expansion-guide)
- [Troubleshooting](#troubleshooting)

## Overview

The home lab uses a **hybrid storage approach**:
- **Longhorn**: Small config volumes and databases (<10GB)
- **MergerFS + SnapRAID + NFS**: Large media volumes (>50GB)

### Why This Architecture?

**Problem**: 867GB data loss during Longhorn disaster recovery due to:
- Large volume (1TB) backup failures
- Inaccessible snapshot chain format
- No direct SSH access to files
- Complex recovery procedures

**Solution**: Filesystem-based storage for large volumes with:
- Direct SSH access (manage files like normal filesystem)
- Incremental backups via restic (deduplication, reliable)
- Disk redundancy via SnapRAID (survive single disk failure)
- Easy expansion (add drives one at a time)
- Simple disaster recovery (restic restore)

## Architecture Comparison

| Aspect | Longhorn (Old) | MergerFS + SnapRAID (New) |
|--------|----------------|---------------------------|
| **Data accessibility** | Exec into pods only | Direct SSH access |
| **Backup reliability** | Failed for 1TB volume | Incremental, deduplicated |
| **Disaster recovery** | Complex (UI restore + rebind) | Simple (restic restore) |
| **Storage efficiency** | 3x replication overhead | 1x parity overhead |
| **Expandability** | Add drives to Longhorn | Add drives to MergerFS |
| **Performance** | Network overhead | Local disk + NFS |
| **Redundancy** | Real-time replicas | Async parity (24h lag) |
| **Config volumes** | Works great ✓ | Keep Longhorn ✓ |
| **Pod portability** | Can run on any node | Must run on Beelink |

## Technology Stack

### MergerFS

**Purpose**: Pool multiple drives into single mount point

**Why chosen**:
- Add drives one at a time (no rebuild required like RAID)
- Individual disks remain readable without array
- Flexible file placement policies
- Lower RAM requirements vs ZFS

**Configuration**:
```bash
/mnt/disk1:/mnt/disk2  /mnt/storage  fuse.mergerfs  \
  defaults,allow_other,use_ino,cache.files=partial,\
  dropcacheonclose=true,category.create=mfs
```

### SnapRAID

**Purpose**: Parity protection for disaster recovery

**Why chosen over mdadm RAID5**:
- Async parity (no write penalty)
- Add drives without rebuild
- Individual disks readable
- Can skip sync if needed

**Limitations**:
- 24-hour parity lag (sync daily)
- Manual sync required (automated via systemd timer)

**Configuration**:
```ini
# /etc/snapraid.conf
parity /mnt/parity1/snapraid.parity
content /var/snapraid.content
content /mnt/disk1/.snapraid.content
content /mnt/disk2/.snapraid.content

data d1 /mnt/disk1/
data d2 /mnt/disk2/

autosave 500
```

### restic

**Purpose**: Incremental backups to MinIO S3

**Why chosen**:
- Deduplication (saves space)
- Incremental backups (only changed chunks)
- Native S3 support
- Proven at scale, mature codebase

**Configuration**:
```bash
# Backup script (/usr/local/bin/backup-media.sh)
export RESTIC_PASSWORD_FILE=/root/.restic-password
export AWS_ACCESS_KEY_ID={{ vault_restic_s3_access_key }}
export AWS_SECRET_ACCESS_KEY={{ vault_restic_s3_secret_key }}

restic -r s3:https://minio.jardoole.xyz/restic-backups backup /mnt/storage/media \
  --tag=media --verbose

restic -r s3:https://minio.jardoole.xyz/restic-backups forget \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

## Beelink Storage Configuration

### Hardware
- **System**: Beelink ME Mini N150 (Intel N150, 12-16GB RAM)
- **Storage**: 3x 2TB NVMe drives (6x M.2 slots total)
- **Capacity**: 4TB usable (2 data + 1 parity)
- **Expansion**: Can add 3 more drives → 8TB usable

### Storage Stack

```
3x 2TB NVMe drives (by-id paths)
    ↓
LUKS Encryption (AES-XTS-256, auto-unlock via keyfile)
    ↓
Individual ext4 filesystems
    ↓
/mnt/disk1 + /mnt/disk2 → MergerFS pool → /mnt/storage (4TB)
/mnt/parity1 → SnapRAID parity
    ↓
NFS export: /mnt/storage → 10.42.0.0/16 (K3s pods)
    ↓
restic backup → s3://minio/restic-backups (daily 3 AM)
SnapRAID sync → daily 4 AM
```

### Directory Structure

```
/mnt/storage/
├── media/                  # Media stack data (NFS mounted by K3s)
│   ├── torrents/           # Download directory (qBittorrent)
│   │   ├── movies/         # Radarr category
│   │   ├── tv/             # Sonarr category
│   │   └── incomplete/     # Partial downloads
│   └── library/            # Final media library
│       ├── movies/         # Jellyfin/Radarr root
│       └── tv/             # Jellyfin/Sonarr root
├── nextcloud/              # Future: Nextcloud data
└── immich/                 # Future: Photo library
```

### Drive Configuration

**group_vars/beelink_nas/main.yml**:
```yaml
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

luks_key_file: "{{ inventory_dir }}/group_vars/beelink_nas/luks.key"
luks_crypt_devices:
  - name: disk1_crypt
    device: "{{ storage_drives[0].device }}"
  - name: disk2_crypt
    device: "{{ storage_drives[1].device }}"
  - name: parity1_crypt
    device: "{{ storage_drives[2].device }}"

mergerfs_mount_point: /mnt/storage
mergerfs_data_drives:
  - /mnt/disk1
  - /mnt/disk2

nfs_exports:
  - path: /mnt/storage
    clients: "10.42.0.0/16(rw,sync,no_subtree_check,no_root_squash)"
```

### Access Methods

**Direct SSH access**:
```bash
# Browse media files
ssh beelink "ls -lh /mnt/storage/media/library/movies"

# Delete a movie manually
ssh beelink "rm /mnt/storage/media/library/movies/OldMovie.mkv"

# Check disk usage
ssh beelink "df -h /mnt/storage"
```

**From K3s pods**:
```bash
# Media apps mount via NFS
kubectl exec -n media deployment/radarr -- ls /data/library/movies
```

## MinIO NAS Storage Configuration

### Hardware
- **System**: Raspberry Pi CM5 on Turing Pi 2
- **Storage**: 2x 2TB HDDs (SATA)
- **Capacity**: 2TB usable (1 data + 1 parity)
- **Expansion**: Can add more HDDs via SATA or USB

### Storage Stack

```
2x 2TB SATA HDDs (by-wwn or by-id paths)
    ↓
Individual XFS filesystems (no LUKS encryption)
    ↓
/mnt/minio-disk1 → MergerFS pool → /mnt/minio-storage (1TB)
/mnt/minio-parity1 → SnapRAID parity
    ↓
MinIO S3 service → /mnt/minio-storage
    ↓
SnapRAID sync → daily 5 AM
```

### MinIO Buckets

```
/mnt/minio-storage/
├── longhorn-backups/       # Longhorn config volume backups
├── restic-backups/         # Media stack restic backups
└── cluster-logs/           # Future: Cluster log aggregation
```

### Drive Configuration

**group_vars/nas/main.yml**:
```yaml
minio_storage_drives:
  - device: /dev/disk/by-id/wwn-0x5000c5008a1a78df
    label: minio-disk1
    mount_point: /mnt/minio-disk1
  - device: /dev/disk/by-id/wwn-0x5000c5008a1a7d0f
    label: minio-parity1
    mount_point: /mnt/minio-parity1

minio_mergerfs_mount: /mnt/minio-storage
minio_mergerfs_data_drives:
  - /mnt/minio-disk1

minio_server_datadirs: "/mnt/minio-storage"
minio_filesystem: xfs  # Object storage optimized
```

## Backup Strategy

### restic Backup (Beelink → MinIO)

**Schedule**: Daily at 3:00 AM

**Retention policy**:
- 7 daily snapshots
- 4 weekly snapshots
- 6 monthly snapshots

**Backup script**: `/usr/local/bin/backup-media.sh`
```bash
#!/bin/bash
set -e

export RESTIC_PASSWORD_FILE=/root/.restic-password
export AWS_ACCESS_KEY_ID={{ vault_restic_s3_access_key }}
export AWS_SECRET_ACCESS_KEY={{ vault_restic_s3_secret_key }}

RESTIC_REPO="s3:https://minio.jardoole.xyz/restic-backups"

# Backup media directory
restic -r $RESTIC_REPO backup /mnt/storage/media \
  --exclude='/mnt/storage/media/torrents/incomplete' \
  --tag=media \
  --verbose

# Cleanup old backups
restic -r $RESTIC_REPO forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

# Verify backup integrity (5% data check)
restic -r $RESTIC_REPO check --read-data-subset=5%
```

**Systemd timer**: `backup-media.timer`
```ini
[Unit]
Description=Daily media backup timer

[Timer]
OnCalendar=daily
OnCalendar=03:00
Persistent=true

[Install]
WantedBy=timers.target
```

### SnapRAID Sync

**Beelink schedule**: Daily at 4:00 AM (after restic backup)

**MinIO schedule**: Daily at 5:00 AM (after Beelink backup)

**Sync script**: `/usr/local/bin/snapraid-sync.sh`
```bash
#!/bin/bash
set -e

# Pre-sync diff
echo "=== SnapRAID Diff ==="
snapraid diff

# Sync parity
echo "=== SnapRAID Sync ==="
snapraid sync

# Verify status
echo "=== SnapRAID Status ==="
snapraid status
```

**Systemd timer**: `snapraid-sync.timer`
```ini
[Unit]
Description=Daily SnapRAID parity sync

[Timer]
OnCalendar=daily
OnCalendar=04:00
Persistent=true

[Install]
WantedBy=timers.target
```

### Backup Verification

**Monthly checks**:
```bash
# Verify restic backup integrity
restic -r s3:https://minio.jardoole.xyz/restic-backups check --read-data

# Verify SnapRAID parity
snapraid scrub -p 10  # Scrub 10% of data
```

## Kubernetes Integration

### NFS Provisioner

**Chart**: `nfs-subdir-external-provisioner`

**Configuration**: `apps/nfs-storage/values.yml`
```yaml
nfs:
  server: beelink
  path: /mnt/storage
  mountOptions:
    - nfsvers=4.2
    - noatime

storageClass:
  name: nfs-media
  defaultClass: false
  accessModes: ReadWriteMany
  reclaimPolicy: Retain
```

### Static NFS PersistentVolume

**Media stack PV**:
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-stack-nfs
spec:
  capacity:
    storage: 4Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-media
  mountOptions:
    - nfsvers=4.2
    - noatime
  nfs:
    server: beelink
    path: /mnt/storage/media
```

### Application Integration Example

**Radarr deployment** (`apps/radarr/values.yml`):
```yaml
persistence:
  config:
    enabled: true
    type: persistentVolumeClaim
    storageClass: longhorn  # Small config volume
    size: 1Gi

  data:
    enabled: true
    type: persistentVolumeClaim
    existingClaim: media-stack-nfs  # Large NFS volume
    globalMounts:
      - path: /data

defaultPodOptions:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                  - beelink  # Run on Beelink (NFS server)
```

### Hardlink Verification

Media stack requires hardlinks to work (save storage by not duplicating files):

```bash
# Test hardlink creation
kubectl exec -n media deployment/radarr -- \
  sh -c 'touch /data/torrents/test.file && ln /data/torrents/test.file /data/library/test.file'

# Verify same inode (hardlink successful)
kubectl exec -n media deployment/radarr -- stat /data/library/test.file
# Links: 2 (should show 2 links)

# Check disk usage
kubectl exec -n media deployment/radarr -- df -h /data
```

## Expansion Guide

### Beelink Expansion (4TB → 8TB)

**Add 2 new drives**:

1. Install 2 new NVMe drives in empty M.2 slots
2. Encrypt with LUKS:
   ```bash
   ssh beelink
   cryptsetup luksFormat /dev/nvme3n1 --key-file /root/.luks/beelink-luks.key
   cryptsetup luksFormat /dev/nvme4n1 --key-file /root/.luks/beelink-luks.key
   cryptsetup open /dev/nvme3n1 disk3_crypt --key-file /root/.luks/beelink-luks.key
   cryptsetup open /dev/nvme4n1 parity2_crypt --key-file /root/.luks/beelink-luks.key
   ```

3. Format and mount:
   ```bash
   mkfs.ext4 -L disk3 /dev/mapper/disk3_crypt
   mkfs.ext4 -L parity2 /dev/mapper/parity2_crypt
   mkdir /mnt/disk3 /mnt/parity2
   mount /dev/mapper/disk3_crypt /mnt/disk3
   mount /dev/mapper/parity2_crypt /mnt/parity2
   ```

4. Update MergerFS:
   ```bash
   # Edit /etc/fstab
   /mnt/disk1:/mnt/disk2:/mnt/disk3  /mnt/storage  fuse.mergerfs  ...

   mount -a
   ```

5. Update SnapRAID:
   ```bash
   # Edit /etc/snapraid.conf
   data d3 /mnt/disk3/
   parity /mnt/parity2/snapraid.parity2

   snapraid sync
   ```

**Result**: 6TB usable (3 data + 2 parity)

### MinIO Expansion (1TB → 3TB)

**Add 2 new HDDs**:

1. Install new SATA HDDs (or USB-connected drives)
2. Format and mount:
   ```bash
   ssh pi-cm5-4
   mkfs.xfs -L minio-disk2 /dev/sdc
   mkfs.xfs -L minio-disk3 /dev/sdd
   mkdir /mnt/minio-disk2 /mnt/minio-disk3
   mount /dev/sdc /mnt/minio-disk2
   mount /dev/sdd /mnt/minio-disk3
   ```

3. Update MergerFS:
   ```bash
   # Edit /etc/fstab
   /mnt/minio-disk1:/mnt/minio-disk2:/mnt/minio-disk3  /mnt/minio-storage  fuse.mergerfs  ...

   mount -a
   ```

4. Update SnapRAID:
   ```bash
   # Edit /etc/snapraid.conf
   data d2 /mnt/minio-disk2/
   data d3 /mnt/minio-disk3/

   snapraid sync
   ```

5. Restart MinIO (automatically sees expanded storage):
   ```bash
   systemctl restart minio
   ```

**Result**: 3TB usable (3 data + 1 parity)

## Troubleshooting

### SnapRAID Parity Errors

**Symptom**: `snapraid status` shows parity errors

**Diagnosis**:
```bash
snapraid diff
snapraid status
```

**Fix**:
```bash
# Sync parity
snapraid sync

# If errors persist, fix using parity
snapraid fix
```

### Disk Failure Simulation

**Beelink data drive failure**:
```bash
# Simulate failure
ssh beelink "umount /mnt/disk2"

# Verify MergerFS still serves files
ssh beelink "ls /mnt/storage/media"

# Reconnect drive
ssh beelink "mount /mnt/disk2"

# Recover corrupted files from parity
ssh beelink "snapraid fix -d disk2"
```

### restic Backup Issues

**Check backup status**:
```bash
ssh beelink "restic -r s3:https://minio.jardoole.xyz/restic-backups snapshots"
```

**Verify repository integrity**:
```bash
ssh beelink "restic -r s3:https://minio.jardoole.xyz/restic-backups check"
```

**Test restore**:
```bash
# Restore to temp location
restic -r s3:https://minio.jardoole.xyz/restic-backups restore latest \
  --target /tmp/restore-test
```

### NFS Mount Issues

**Check NFS exports**:
```bash
showmount -e beelink
```

**Check NFS service**:
```bash
ssh beelink "systemctl status nfs-kernel-server"
```

**Test manual NFS mount**:
```bash
mkdir /tmp/nfs-test
mount -t nfs -o nfsvers=4.2,noatime beelink:/mnt/storage /tmp/nfs-test
ls /tmp/nfs-test
umount /tmp/nfs-test
```

### Hardlink Issues

**Symptom**: Disk usage doubled (hardlinks not working)

**Diagnosis**:
```bash
# Check if same filesystem
kubectl exec -n media deployment/radarr -- df /data/torrents /data/library

# Check inode numbers (should match)
kubectl exec -n media deployment/radarr -- ls -li /data/torrents/movie.mkv
kubectl exec -n media deployment/radarr -- ls -li /data/library/movie.mkv
```

**Fix**:
- Ensure all apps mount same NFS export (not subpaths)
- Radarr: Settings → Media Management → Use Hardlinks instead of Copy
- Re-import media

## Related Documentation

- [Project Structure](project-structure.md) - Variable configuration
- [App Deployment Guide](app-deployment-guide.md) - Storage selection for apps
- [Disaster Recovery Guide](disaster-recovery.md) - Backup and restore procedures
- [Beelink Storage Setup](beelink-storage-setup.md) - Hardware configuration
