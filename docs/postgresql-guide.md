# PostgreSQL Guide

Complete guide for using CloudNative PostgreSQL (CNPG) in the home-lab cluster.

## Overview

CloudNative-PG provides:
- Automated PostgreSQL cluster management
- Self-healing with automatic failover
- Native backups to S3 (MinIO)
- Point-in-time recovery (PITR)
- Rolling updates with zero downtime

## When to Use CNPG

| Use Case | Recommendation |
|----------|----------------|
| App requires PostgreSQL | Use CNPG Cluster |
| Simple key-value storage | Consider Redis or SQLite |
| Embedded database | Use app's built-in SQLite |
| High-availability required | CNPG with 3 instances |

## Quick Start

### 1. Deploy the Operator

```bash
make app-deploy APP=cloudnative-pg
```

### 2. Create Database Credentials

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-db-credentials
  namespace: myapp
type: kubernetes.io/basic-auth
stringData:
  username: myapp
  password: "{{ vault_myapp_db_password }}"
```

### 3. Create PostgreSQL Cluster

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: myapp-db
  namespace: myapp
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  storage:
    size: 5Gi
    storageClass: nfs

  bootstrap:
    initdb:
      database: myapp
      owner: myapp
      secret:
        name: myapp-db-credentials
```

### 4. Connect Your App

Use the auto-generated `myapp-db-app` secret:

```yaml
env:
  DATABASE_URL:
    valueFrom:
      secretKeyRef:
        name: myapp-db-app
        key: uri
```

## Cluster Patterns

### Single Instance (Development/Light Workloads)

```yaml
spec:
  instances: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  storage:
    size: 5Gi
    storageClass: nfs
```

### High Availability (3 Instances)

```yaml
spec:
  instances: 3
  primaryUpdateStrategy: unsupervised

  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

  storage:
    size: 10Gi
    storageClass: nfs

  affinity:
    podAntiAffinityType: required  # Spread across nodes
```

### With Backup to MinIO

```yaml
spec:
  instances: 1

  storage:
    size: 5Gi
    storageClass: nfs

  backup:
    barmanObjectStore:
      destinationPath: s3://postgres-backups/myapp
      endpointURL: https://minio.jardoole.xyz:9000
      s3Credentials:
        accessKeyId:
          name: cnpg-s3-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: cnpg-s3-credentials
          key: ACCESS_SECRET_KEY
    retentionPolicy: "7d"
```

## Credential Management

### Vault Integration

Add database passwords to `group_vars/all/vault.yml`:

```yaml
# Per-app database passwords
vault_authentik_db_password: "secure-generated-password"
vault_nextcloud_db_password: "another-secure-password"
```

### S3 Backup Credentials

Add MinIO credentials for backups:

```yaml
# CNPG S3 backup credentials (MinIO)
vault_cnpg_s3_access_key: "cnpg-backup-access-key"
vault_cnpg_s3_secret_key: "cnpg-backup-secret-key"
```

### Secret Structure

The operator creates these secrets automatically:

| Secret | Purpose | Keys |
|--------|---------|------|
| `<cluster>-app` | Application connection | `host`, `port`, `dbname`, `user`, `password`, `uri` |
| `<cluster>-superuser` | Admin access | Same keys with superuser credentials |
| `<cluster>-ca` | TLS CA certificate | `ca.crt` |

## Resource Sizing

### Pi CM5 Recommendations

| Profile | CPU Req | CPU Limit | Mem Req | Mem Limit | Use Case |
|---------|---------|-----------|---------|-----------|----------|
| Minimal | 50m | 250m | 128Mi | 256Mi | Config storage |
| Light | 100m | 500m | 256Mi | 512Mi | Small apps |
| Medium | 250m | 1000m | 512Mi | 1Gi | Standard apps |
| Heavy | 500m | 2000m | 1Gi | 2Gi | Analytics, large datasets |

### Storage Sizing

| Use Case | Recommended Size |
|----------|-----------------|
| Config database | 1-2Gi |
| Application database | 5-10Gi |
| Media metadata | 10-20Gi |
| Analytics/logs | 50Gi+ |

## Backup and Recovery

### Backup Architecture

```
PostgreSQL Cluster
        │
        ▼
   pg_basebackup + WAL archiving
        │
        ▼
   barman (CNPG integrated)
        │
        ▼
   MinIO S3 (postgres-backups bucket)
```

### Manual Backup

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: myapp-db-backup-manual
  namespace: myapp
spec:
  cluster:
    name: myapp-db
```

### List Backups

```bash
kubectl get backup -n <namespace>
```

### Restore from Backup

Create a new cluster from backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: myapp-db-restored
  namespace: myapp
spec:
  instances: 1

  storage:
    size: 5Gi
    storageClass: nfs

  bootstrap:
    recovery:
      source: myapp-db-backup

  externalClusters:
    - name: myapp-db-backup
      barmanObjectStore:
        destinationPath: s3://postgres-backups/myapp
        endpointURL: https://minio.jardoole.xyz:9000
        s3Credentials:
          accessKeyId:
            name: cnpg-s3-credentials
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: cnpg-s3-credentials
            key: ACCESS_SECRET_KEY
```

### Point-in-Time Recovery

Restore to a specific timestamp:

```yaml
bootstrap:
  recovery:
    source: myapp-db-backup
    recoveryTarget:
      targetTime: "2024-01-15T10:30:00Z"
```

## Monitoring

### Check Cluster Status

```bash
# Overview
kubectl get cluster -A

# Detailed status
kubectl describe cluster myapp-db -n myapp

# Pod status
kubectl get pods -n myapp -l cnpg.io/cluster=myapp-db
```

### View Logs

```bash
# Database logs
kubectl logs myapp-db-1 -n myapp

# Operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg
```

### Prometheus Metrics

CNPG exports metrics on port 9187. Add to Prometheus scrape config:

```yaml
additionalScrapeConfigs:
  - job_name: 'cnpg'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_cnpg_io_cluster]
        action: keep
        regex: .+
```

## Troubleshooting

### Cluster Stuck in "Setting up primary"

1. Check operator logs for errors
2. Verify PVC is bound: `kubectl get pvc -n <namespace>`
3. Check storage class: `kubectl get sc nfs`

### Connection Timeouts

1. Verify cluster is ready: `kubectl get cluster -n <namespace>`
2. Check service exists: `kubectl get svc -n <namespace> | grep <cluster>`
3. Test DNS: `kubectl run test --rm -it --image=busybox -- nslookup <cluster>-rw.<namespace>`

### Backup Failures

1. Check MinIO connectivity from cluster
2. Verify S3 credentials secret exists
3. Check MinIO bucket permissions
4. View backup status: `kubectl describe backup <name> -n <namespace>`

### WAL Archiving Failures

1. Check cluster events for archive errors
2. Verify MinIO storage quota
3. Check network policy allows egress to MinIO

## Best Practices

1. **One cluster per app** - Isolates failures and simplifies management
2. **Always set resource limits** - Prevents resource exhaustion
3. **Use initdb secrets** - Don't hardcode passwords
4. **Enable backups for production** - MinIO is already available
5. **Test restores periodically** - Verify backup integrity
6. **Pin PostgreSQL versions** - Use specific image tags

## Related Documentation

- [App README](../apps/cloudnative-pg/README.md) - Operator deployment details
- [App Deployment Guide](app-deployment-guide.md) - Standard app patterns
- [Disaster Recovery](disaster-recovery.md) - Backup procedures
- [MinIO Usage](minio-usage.md) - S3 storage operations
