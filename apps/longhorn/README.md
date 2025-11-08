# Longhorn

Distributed block storage system for Kubernetes persistent volumes.

## Overview

Longhorn provides cloud-native distributed block storage with enterprise-grade features:
- **Distributed replicas**: Automatic volume replication across nodes
- **Snapshots and backups**: Point-in-time recovery and external backup support
- **Volume management**: Web UI for volume lifecycle management
- **CSI driver**: Full Kubernetes CSI integration

## Dependencies

- **System packages**: open-iscsi, nfs-common, nfs-kernel-server (installed by orchestration playbook)
- **Traefik**: For ingress routing to Longhorn UI
- **cert-manager**: For TLS certificate provisioning

## Configuration

### Storage Settings
- **Replica count**: 1 (configured for single worker node)
- **Data locality**: best-effort (prefer same node as workload)
- **Soft anti-affinity**: Enabled (allows replicas on same node when needed)
- **Default storage class**: Enabled (Longhorn becomes default for PVCs)
- **Reclaim policy**: Retain (volumes preserved when PVC deleted)

### CSI Driver
- **Kubelet root dir**: /var/lib/kubelet (K3s v0.10.0+ standard path)
- **Storage path**: /var/lib/longhorn on worker nodes

### Ingress
- **URL**: https://longhorn.jardoole.xyz
- **TLS**: Let's Encrypt certificate via cert-manager
- **Entrypoint**: websecure (HTTPS)

## Deployment

Deploy via orchestration playbook (recommended for cluster setup):
```bash
make k3s-storage
```

Or deploy standalone:
```bash
make app-deploy APP=longhorn
```

## Access

**Longhorn UI**: https://longhorn.jardoole.xyz

## Backup Configuration

### External Backup Target

Longhorn is configured to back up volumes to external MinIO S3 storage on NAS node (pi-cm5-4):

- **Backup Target**: `s3://longhorn-backups@eu-west-1/`
- **Endpoint**: `https://minio.jardoole.xyz`
- **Credentials**: Stored in Kubernetes secret `longhorn-backup-target-credential`
- **Configuration**: `group_vars/longhorn/main.yml`

**Why external storage**: MinIO runs outside the Kubernetes cluster, ensuring backups survive complete cluster failures.

### Automated Recurring Jobs

Four recurring jobs run automatically to protect your data:

| Job | Schedule | Purpose | Retention |
|-----|----------|---------|-----------|
| **daily-backup** | Daily 2:00 AM | Volume data backup to MinIO | 7 days |
| **weekly-backup** | Sunday 3:00 AM | Weekly volume backup to MinIO | 4 weeks |
| **snapshot-cleanup** | Daily 6:00 AM | Remove old local snapshots | 1 generation |
| **weekly-system-backup** | Sunday 4:00 AM | Cluster config backup | 4 weeks |

**Configuration**: `apps/longhorn/prerequisites.yml`

**Verify recurring jobs**:
```bash
kubectl get recurringjobs.longhorn.io -n longhorn-system
```

### Backup Types

**Volume Backups** (Daily/Weekly):
- Backs up actual volume data (filesystem blocks)
- Stored in MinIO: `s3://longhorn-backups/backups/<volume-name>/`
- Used for restoring individual volumes or full cluster

**System Backups** (Weekly):
- Backs up Longhorn configuration (Volume CRDs, Settings, RecurringJobs)
- Stored in MinIO: `s3://longhorn-backups/system-backups/`
- Enables bulk restore of all volumes after cluster rebuild
- Size: Usually < 1MB (metadata only)

### Verify Backups

**Check backup target connection**:
```bash
# Via kubectl
kubectl get settings.longhorn.io backup-target -n longhorn-system -o yaml

# Via Longhorn UI
# Settings → Backup Target (should show green checkmark)
```

**View backups in MinIO**:
```bash
ssh alexanderp@pi-cm5-4
sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/
sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/system-backups/
```

### Disaster Recovery

For complete disaster recovery procedures, see:
- **[Disaster Recovery Guide](../../docs/longhorn-disaster-recovery.md)** - Comprehensive recovery procedures
- Recovery scenarios (single volume, full cluster rebuild)
- RTO/RPO objectives: 30-45 min RTO, 24 hour RPO
- Troubleshooting common issues

## Maintenance

### Upgrade Longhorn
1. Update `chart_version` in Chart.yml
2. Review breaking changes in [Longhorn releases](https://github.com/longhorn/longhorn/releases)
3. Redeploy: `make app-deploy APP=longhorn`

### Storage Path Verification
Check worker node storage:
```bash
ansible worker -m shell -a "ls -lh /var/lib/longhorn" --become
```

### Volume Management
- View volumes: Longhorn UI → Volume tab
- Create snapshots: Volume → Snapshot button
- Configure backups: Settings → Backup Target

## Troubleshooting

### Pods stuck in Pending
Check node storage capacity:
```bash
kubectl get nodes
kubectl describe node <worker-node>
```

### CSI Driver Issues
Verify CSI pods are running:
```bash
kubectl get pods -n longhorn-system -l app=csi-attacher
kubectl get pods -n longhorn-system -l app=csi-provisioner
```

Check CSI registration:
```bash
kubectl get csidrivers
kubectl get csinodes
```

### Ingress Not Working
Verify ingress configuration:
```bash
kubectl get ingress -n longhorn-system
kubectl describe ingress longhorn-ui -n longhorn-system
```

Check certificate status:
```bash
kubectl get certificate -n longhorn-system
```

## References

- [Longhorn Documentation](https://longhorn.io/docs/1.10.0/)
- [CSI on K3s](https://longhorn.io/docs/1.10.0/advanced-resources/os-distro-specific/csi-on-k3s/)
- [Best Practices](https://longhorn.io/docs/1.10.0/best-practices/)
