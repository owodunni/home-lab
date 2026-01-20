# Backrest

Web UI for managing restic backups. Provides browse/restore capabilities for the existing restic repository.

## Overview

Backrest connects to the existing restic backup repository (hosted on MinIO S3) and provides:
- Browse snapshots and files
- Restore files/directories
- View backup statistics
- Schedule and monitor backups

## Dependencies

- NFS storage (for persistent state)
- cert-manager (TLS certificates)
- MinIO S3 (backup storage backend)
- Existing restic repository at `s3:https://minio.jardoole.xyz:9000/restic-backups`

## Access

- **URL**: <https://backrest.jardoole.xyz>

## Deployment

```bash
make app-deploy APP=backrest
```

## Configuration

### Vault Secrets (pre-existing)

The following secrets from `group_vars/all/vault.yml` are used:

| Variable | Purpose |
|----------|---------|
| `vault_restic_password` | Restic repository encryption password |
| `vault_restic_s3_access_key` | MinIO S3 access key |
| `vault_restic_s3_secret_key` | MinIO S3 secret key |

### First-Time Setup

After deployment, open the web UI and configure:

1. Navigate to <https://backrest.jardoole.xyz>
2. Add a new repository with pre-configured credentials (loaded from environment)
3. Verify snapshots are visible

## Existing Backup Structure

The beelink NAS runs daily backups at 3:00 AM with these tags:

| Tag | Source | Contents |
|-----|--------|----------|
| `k8s-apps` | `/mnt/storage/k8s-apps` | Kubernetes application data |
| `media` | `/mnt/storage/media` | Media library (excludes torrents/incomplete) |

## Troubleshooting

### Pod fails to start

Check for the BACKREST_PORT conflict (Kubernetes service discovery):

```bash
kubectl describe pod -n backrest -l app.kubernetes.io/name=backrest
```

The deployment uses `enableServiceLinks: false` to prevent this issue.

### Cannot connect to MinIO

Verify network policy allows egress to MinIO:

```bash
kubectl get networkpolicy -n backrest
kubectl logs -n backrest -l app.kubernetes.io/name=backrest
```

### View restic credentials

```bash
kubectl get secret -n backrest backrest-restic-credentials -o yaml
```

## Manual Restic Commands

For CLI access, SSH to beelink and use:

```bash
# List snapshots
restic -r s3:https://minio.jardoole.xyz:9000/restic-backups snapshots

# List by tag
restic -r s3:https://minio.jardoole.xyz:9000/restic-backups snapshots --tag k8s-apps

# Browse snapshot
restic -r s3:https://minio.jardoole.xyz:9000/restic-backups ls <snapshot-id>

# Restore file
restic -r s3:https://minio.jardoole.xyz:9000/restic-backups restore <snapshot-id> --target /tmp/restore --include <path>
```

## References

- [Backrest GitHub](https://github.com/garethgeorge/backrest)
- [Restic Documentation](https://restic.readthedocs.io/)
- [Disaster Recovery Guide](../../docs/disaster-recovery.md)
