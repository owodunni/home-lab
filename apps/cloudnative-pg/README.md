# CloudNative PostgreSQL Operator

PostgreSQL operator for Kubernetes that manages PostgreSQL clusters with automated failover, backups, and rolling updates.

## Dependencies

- K3s cluster with Helm installed
- cert-manager (required for Barman Cloud Plugin)
- NFS storage class (for persistent volumes)
- MinIO (optional, for S3 backups)

## What Gets Installed

1. **CloudNative-PG Operator** - Manages PostgreSQL clusters
2. **Barman Cloud Plugin** - Handles S3 backups (installed automatically as post-install)

## Deployment

```bash
make app-deploy APP=cloudnative-pg
```

## Verification

```bash
# Check operator is running
kubectl get pods -n cnpg-system

# Check Barman Cloud Plugin is running
kubectl get pods -n cnpg-system -l app.kubernetes.io/name=barman-cloud

# Check CRDs are installed
kubectl get crd | grep -E "(cnpg|barman)"
```

## Creating PostgreSQL Clusters

The operator manages PostgreSQL via `Cluster` custom resources. Create a cluster per application.

### Basic Cluster (No Backup)

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

### Cluster with S3 Backup (Barman Cloud Plugin)

First, create the ObjectStore resource:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: myapp-db-backup
  namespace: myapp
spec:
  configuration:
    destinationPath: s3://postgres-backups/myapp
    endpointURL: https://minio.jardoole.xyz:9000
    s3Credentials:
      accessKeyId:
        name: cnpg-s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: cnpg-s3-credentials
        key: ACCESS_SECRET_KEY
    wal:
      compression: gzip
  retentionPolicy: "7d"
```

Then reference it in the Cluster:

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

  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: myapp-db-backup
```

## Required Secrets

### Database Credentials (per app)

Create in the app's namespace before deploying the Cluster:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-db-credentials
  namespace: myapp
type: kubernetes.io/basic-auth
stringData:
  username: myapp
  password: "your-secure-password"  # Use vault variable
```

### S3 Credentials (for backups)

Create in each namespace that uses backups:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cnpg-s3-credentials
  namespace: myapp
type: Opaque
stringData:
  ACCESS_KEY_ID: "cnpg-backup-access-key"
  ACCESS_SECRET_KEY: "cnpg-backup-secret-key"
```

## Using Credentials in Applications

When using `bootstrap.initdb.secret`, CNPG uses that same secret for application connections. The password key in that secret contains the database password.

### Example: Using Bootstrap Secret

```yaml
env:
  - name: DATABASE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: myapp-db-credentials  # Same as bootstrap secret
        key: password
```

## Resource Sizing for Pi CM5

Recommended resource limits for single-instance clusters on ARM64:

| Workload | CPU Request | CPU Limit | Memory Request | Memory Limit |
|----------|-------------|-----------|----------------|--------------|
| Light (config DBs) | 100m | 500m | 256Mi | 512Mi |
| Medium (app DBs) | 250m | 1000m | 512Mi | 1Gi |
| Heavy (analytics) | 500m | 2000m | 1Gi | 2Gi |

## Backup Strategy

### Why Barman Cloud Plugin?

- **Database-consistent**: Uses `pg_basebackup` for consistent snapshots
- **Point-in-time recovery**: WAL archiving enables PITR
- **Plugin architecture**: Future-proof, replacing deprecated in-tree backup
- **Separate lifecycle**: ObjectStore can be managed independently

### Backrest Exclusions

To prevent double-backup (restic + CNPG), add exclusions in Backrest UI for `k8s-apps-daily`:
- `**/pgdata/**` - PostgreSQL data directories
- `**/*-db-1/**` - CNPG cluster PVC naming pattern

Configure via Backrest UI at https://backrest.jardoole.xyz

## Maintenance

### View Cluster Status

```bash
kubectl get cluster -n <namespace>
kubectl describe cluster <cluster-name> -n <namespace>
```

### View ObjectStore Status

```bash
kubectl get objectstore -n <namespace>
kubectl describe objectstore <store-name> -n <namespace>
```

### View Logs

```bash
# Operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg

# Barman Cloud Plugin logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=barman-cloud

# Database logs
kubectl logs -n <namespace> <cluster-name>-1
```

### Manual Backup

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: myapp-db-backup-$(date +%Y%m%d)
  namespace: myapp
spec:
  cluster:
    name: myapp-db
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: myapp-db-backup
EOF
```

### Restore from Backup

See [postgresql-guide.md](../../docs/postgresql-guide.md) for restore procedures.

## Troubleshooting

### Cluster Not Starting

1. Check operator logs: `kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg`
2. Check cluster events: `kubectl describe cluster <name> -n <namespace>`
3. Verify storage class exists: `kubectl get sc nfs`

### Backup Not Working

1. Check Barman Cloud Plugin: `kubectl get pods -n cnpg-system -l app.kubernetes.io/name=barman-cloud`
2. Check ObjectStore status: `kubectl describe objectstore <name> -n <namespace>`
3. Verify S3 credentials: `kubectl get secret cnpg-s3-credentials -n <namespace>`

### Connection Refused

1. Check pod is running: `kubectl get pods -n <namespace> -l cnpg.io/cluster=<cluster-name>`
2. Check service exists: `kubectl get svc -n <namespace>`
3. Verify credentials secret exists

## Related Documentation

- [PostgreSQL Guide](../../docs/postgresql-guide.md) - Complete PostgreSQL usage guide
- [App Deployment Guide](../../docs/app-deployment-guide.md) - Standard app deployment
- [Disaster Recovery](../../docs/disaster-recovery.md) - Backup and restore procedures
