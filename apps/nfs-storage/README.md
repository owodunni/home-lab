# NFS Storage Provisioner

NFS subdir external provisioner for Beelink filesystem-based storage. Provides dynamic provisioning of NFS-backed PersistentVolumes.

## Overview

- **Chart**: kubernetes-sigs/nfs-subdir-external-provisioner v4.0.18
- **Storage Class**: `nfs-media` (not default)
- **NFS Server**: beelink (Beelink ME Mini N150)
- **NFS Path**: `/mnt/storage` (MergerFS pool)
- **Access Modes**: ReadWriteMany (RWX)
- **Reclaim Policy**: Retain (data preserved on PVC delete)

## When to Use This Storage

Use `nfs-media` storage class for:
- **Large media volumes** (>50GB) - Movies, TV shows, photos
- **Data needing SSH access** - Files you want to manage manually
- **Applications requiring hardlinks** - Media stack (Radarr, Sonarr, etc.)
- **Volumes needing incremental backups** - restic backs up to MinIO S3

See [Storage Selection Guide](../../docs/app-deployment-guide.md#storage-selection) for complete guidance.

## Dependencies

- **Beelink**: MergerFS + SnapRAID configured on Beelink
- **NFS server**: Running on Beelink, exporting `/mnt/storage`
- **Network**: K3s pods can reach Beelink via hostname

## Deployment

```bash
# Deploy NFS provisioner
make app-deploy APP=nfs-storage

# Verify deployment
kubectl get pods -n kube-system -l app=nfs-subdir-external-provisioner
kubectl get storageclass nfs-media
```

## Example Usage

### Static PV for Media Stack

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

### Dynamic PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-data
  namespace: applications
spec:
  storageClassName: nfs-media
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 500Gi
```

## Verification

```bash
# Check NFS exports on Beelink
showmount -e beelink

# Test NFS mount manually
mkdir /tmp/nfs-test
mount -t nfs -o nfsvers=4.2,noatime beelink:/mnt/storage /tmp/nfs-test
ls /tmp/nfs-test
umount /tmp/nfs-test
```

## Troubleshooting

### Pods can't mount NFS volumes

**Check NFS server is running**:
```bash
ssh beelink "systemctl status nfs-kernel-server"
ssh beelink "exportfs -v"
```

**Check network connectivity**:
```bash
kubectl run -it --rm debug --image=busybox --restart=Never -- \
  sh -c "ping -c 3 beelink && nslookup beelink"
```

### Provisioner pod not starting

**Check logs**:
```bash
kubectl logs -n kube-system -l app=nfs-subdir-external-provisioner
```

**Common issues**:
- NFS server not running on Beelink
- Firewall blocking NFS ports (2049, 111)
- Incorrect hostname (should be `beelink`)

## Maintenance

### Resize PVC

NFS volumes can be resized by editing the PVC:
```bash
kubectl edit pvc nextcloud-data -n applications
# Change: storage: 500Gi → storage: 1Ti
```

No provisioner action needed - NFS is elastic.

### Backup

NFS-backed data is automatically backed up via:
- **restic**: Daily incremental backups to MinIO S3 (3:00 AM)
- **SnapRAID**: Daily parity sync for disaster recovery (4:00 AM)

See [Disaster Recovery Guide](../../docs/disaster-recovery.md) for restore procedures.

## Related Documentation

- [Storage Architecture](../../docs/storage-architecture.md) - Complete storage architecture
- [App Deployment Guide](../../docs/app-deployment-guide.md#storage-selection) - Storage selection guidance
- [Media Stack Guide](../../docs/media-stack-complete-guide.md) - NFS usage example
