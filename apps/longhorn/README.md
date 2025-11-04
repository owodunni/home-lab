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
