# Backrest

Web UI for managing restic backups with scheduled backup automation and restore capabilities.

**Stack**: Backrest (Web UI) + Restic (backup engine) + MinIO S3 (storage backend)

## Architecture Overview

### Data Flow

```
Source Data (Beelink NFS)
         |
    Backrest (schedule + orchestrate)
         |
    Restic (deduplicate + encrypt)
         |
    MinIO S3 (s3:https://minio.jardoole.xyz:9000/restic-backups)
         |
    SnapRAID Parity (MinIO NAS disk protection)
```

### Storage Layout

```
Beelink NFS (/mnt/storage/)     Backrest Pod Mounts
├── k8s-apps/                →  /backup-sources/k8s-apps
│   ├── radarr-config/
│   ├── sonarr-config/
│   └── ...
└── media/                   →  /backup-sources/media
    ├── torrents/
    └── library/
```

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

## Vault Secrets

The following secrets from `group_vars/all/vault.yml` are used:

| Variable                     | Purpose                               |
| ---------------------------- | ------------------------------------- |
| `vault_restic_password`      | Restic repository encryption password |
| `vault_restic_s3_access_key` | MinIO S3 access key                   |
| `vault_restic_s3_secret_key` | MinIO S3 secret key                   |

## Configuration Guide

### Step 1: Verify NFS Mounts

After deployment, verify NFS mounts are accessible:

```bash
# Check pod is running
kubectl get pods -n backrest

# Verify NFS mounts
kubectl exec -n backrest deploy/backrest -- ls /backup-sources/k8s-apps
kubectl exec -n backrest deploy/backrest -- ls /backup-sources/media
```

### Step 2: Add Repository

1. Open <https://backrest.jardoole.xyz>
2. Click "Add Repo"
3. Get credentials from the Kubernetes secret:

```bash
kubectl get secret -n backrest backrest-restic-credentials -o jsonpath='{.data.RESTIC_REPOSITORY}' | base64 -d && echo
kubectl get secret -n backrest backrest-restic-credentials -o jsonpath='{.data.RESTIC_PASSWORD}' | base64 -d && echo
kubectl get secret -n backrest backrest-restic-credentials -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d && echo
kubectl get secret -n backrest backrest-restic-credentials -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d && echo
```

4. Configure in UI:

| Field              | Value                                              |
| ------------------ | -------------------------------------------------- |
| **Name**           | `minio-backups`                                    |
| **Repository URI** | `s3:https://minio.jardoole.xyz:9000/restic-backups` |
| **Password**       | (paste from secret)                                |

5. Add environment variables (paste values from secret):

```
AWS_ACCESS_KEY_ID=<value from secret>
AWS_SECRET_ACCESS_KEY=<value from secret>
```

### Step 3: Create K8s Apps Backup Plan

1. Click "Add Plan"
2. Configure:

| Field            | Value                       |
| ---------------- | --------------------------- |
| **Plan Name**    | `k8s-apps-daily`            |
| **Repository**   | `minio-backups`             |
| **Paths**        | `/backup-sources/k8s-apps`  |
| **Tags**         | `k8s-apps`                  |
| **Schedule**     | `0 3 * * *` (3:00 AM daily) |
| **Keep Daily**   | `7`                         |
| **Keep Weekly**  | `4`                         |
| **Keep Monthly** | `6`                         |

3. (Optional) Add post-backup hook: `check --read-data-subset=5%`

### Step 4: Create Media Backup Plan

1. Click "Add Plan"
2. Configure:

| Field            | Value                        |
| ---------------- | ---------------------------- |
| **Plan Name**    | `media-daily`                |
| **Repository**   | `minio-backups`              |
| **Paths**        | `/backup-sources/media`      |
| **Tags**         | `media`                      |
| **Schedule**     | `15 3 * * *` (3:15 AM daily) |
| **Keep Daily**   | `7`                          |
| **Keep Weekly**  | `4`                          |
| **Keep Monthly** | `6`                          |

3. Add exclusions:
   - `torrents/incomplete/**`
   - `**/*.tmp`
   - `**/*.part`

### Step 5: Test and Migrate

1. Trigger manual backup for both plans
2. Verify snapshots appear in UI
3. Disable systemd backups on beelink:

```bash
ssh beelink
sudo systemctl stop backup-media.timer
sudo systemctl disable backup-media.timer
```

## Restore Procedures

### Via Web UI

1. Open <https://backrest.jardoole.xyz>
2. Go to Snapshots tab
3. Filter by tag (`k8s-apps` or `media`)
4. Browse to file/directory
5. Click "Restore" or "Download"

### Via CLI

```bash
# Exec into backrest pod
kubectl exec -it -n backrest deploy/backrest -- sh

# List snapshots
restic snapshots

# List by tag
restic snapshots --tag k8s-apps

# Restore specific file
restic restore <snapshot-id> --target / --include "/backup-sources/k8s-apps/radarr-config/radarr.db"
```

### Full Application Restore

```bash
# 1. Stop the application
kubectl scale deployment radarr -n media --replicas=0

# 2. Restore via UI or CLI

# 3. Restart application
kubectl scale deployment radarr -n media --replicas=1
```

## Troubleshooting

### Pod fails to start

Check for the BACKREST_PORT conflict:

```bash
kubectl describe pod -n backrest -l app.kubernetes.io/name=backrest
```

The deployment uses `enableServiceLinks: false` to prevent this issue.

### Cannot connect to MinIO

```bash
# Verify network policy
kubectl get networkpolicy -n backrest

# Test connectivity from pod
kubectl exec -n backrest deploy/backrest -- wget -qO- https://minio.jardoole.xyz:9000/minio/health/live
```

### NFS mounts not accessible

```bash
# Check volume mounts
kubectl describe pod -n backrest -l app.kubernetes.io/name=backrest | grep -A 20 "Mounts:"

# Verify NFS server
ssh beelink "systemctl status nfs-server"
```

### Backup fails with permission denied

1. Check NFS export options include `no_root_squash`
2. Verify backrest runs as UID 1000 (matches NFS permissions)

## Quick Reference

```bash
# Pod status
kubectl get pods -n backrest

# Pod logs
kubectl logs -n backrest deploy/backrest --tail=100 -f

# Exec into pod
kubectl exec -it -n backrest deploy/backrest -- sh
```

## Emergency: Re-enable Systemd Backups

```bash
ssh beelink
sudo systemctl enable --now backup-media.timer
```

## References

- [Backrest GitHub](https://github.com/garethgeorge/backrest)
- [Restic Documentation](https://restic.readthedocs.io/)
- [Disaster Recovery Guide](../../docs/disaster-recovery.md)
