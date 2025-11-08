# PostgreSQL Test Database

Test database for validating Longhorn backup and restore functionality.

## Purpose

This PostgreSQL instance is used exclusively for testing the Longhorn backup/restore workflow:
1. Deploy stateful app with Longhorn storage
2. Generate verifiable test data
3. Create backups to MinIO
4. Test destructive restore scenarios
5. Verify 100% data integrity

## Configuration

- **Chart**: bitnami/postgresql 16.5.0
- **Namespace**: test-backups
- **Storage**: 2Gi Longhorn PVC (backup-enabled)
- **Resources**: Small (100m CPU, 256Mi RAM)
- **Database**: testdb
- **User**: testuser
- **Password**: Stored in vault as `vault_postgres_test_password`

## Dependencies

- Longhorn (storage)
- MinIO backup target configured
- Recurring backup jobs enabled

## Deployment

```bash
# Deploy PostgreSQL test instance
make app-deploy APP=postgres-test

# Verify deployment
kubectl get pods -n test-backups
kubectl get pvc -n test-backups

# Check Longhorn volume created
kubectl get volumes.longhorn.io -n longhorn-system | grep pvc
```

## Testing Backup & Restore

### 1. Connect to Database

```bash
# Get PostgreSQL password from vault
uv run ansible-vault view group_vars/all/vault.yml | grep vault_postgres_test_password

# Connect using psql client pod
kubectl run -it --rm psql-client --image=postgres:16 --restart=Never -n test-backups -- \
  psql -h postgres-test-postgresql.test-backups.svc.cluster.local -U testuser -d testdb
```

You'll be prompted for password (use value from vault).

### 2. Generate Test Data

```sql
-- Create test table
CREATE TABLE test_data (
  id SERIAL PRIMARY KEY,
  name VARCHAR(100),
  created_at TIMESTAMP DEFAULT NOW()
);

-- Insert 1000 test rows
INSERT INTO test_data (name)
SELECT 'User ' || generate_series(1, 1000);

-- Verify count
SELECT COUNT(*) FROM test_data;
-- Expected: 1000

-- Sample data
SELECT * FROM test_data LIMIT 5;

-- Exit
\q
```

### 3. Create Manual Backup

1. Open Longhorn UI: https://longhorn.jardoole.xyz
2. Navigate to **Volume** tab
3. Find volume starting with `pvc-` (attached to test-backups namespace)
4. Click volume → **Create Backup**
5. Wait for backup to complete (~1-2 minutes)
6. Note the backup name (e.g., `backup-abc123def456`)

**Verify in MinIO:**
```bash
ssh alexanderp@pi-cm5-4 "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/"
```

### 4. Destructive Test - Delete Volume

**WARNING**: This deletes all data. Ensure backup completed first!

```bash
# Scale down StatefulSet
kubectl scale statefulset postgres-test-postgresql -n test-backups --replicas=0

# Wait for pod to terminate
kubectl wait --for=delete pod/postgres-test-postgresql-0 -n test-backups --timeout=120s

# Delete PVC (destroys volume)
kubectl delete pvc data-postgres-test-postgresql-0 -n test-backups

# Verify volume deleted in Longhorn UI
```

### 5. Restore Volume from Backup

**In Longhorn UI:**
1. Navigate to **Backup** tab
2. Find your backup (filter by namespace or timestamp)
3. Click backup → **Restore**
4. Volume name: `postgres-data-restored`
5. Wait for restore to complete (~2-5 minutes)

### 6. Create PV for Restored Volume

Save this as `postgres-pv.yml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-data-pv
spec:
  capacity:
    storage: 2Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: postgres-data-restored
    volumeAttributes:
      numberOfReplicas: "1"
      staleReplicaTimeout: "30"
```

Apply:
```bash
kubectl apply -f postgres-pv.yml
```

### 7. Create PVC Bound to Restored Volume

Save this as `postgres-pvc.yml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-postgres-test-postgresql-0
  namespace: test-backups
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: longhorn
  volumeName: postgres-data-pv
```

Apply:
```bash
kubectl apply -f postgres-pvc.yml

# Verify PVC bound
kubectl get pvc -n test-backups
```

### 8. Scale Up PostgreSQL

```bash
# Scale back to 1 replica
kubectl scale statefulset postgres-test-postgresql -n test-backups --replicas=1

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/postgres-test-postgresql-0 -n test-backups --timeout=120s
```

### 9. Verify Data Integrity

```bash
# Connect to database again
kubectl run -it --rm psql-client --image=postgres:16 --restart=Never -n test-backups -- \
  psql -h postgres-test-postgresql.test-backups.svc.cluster.local -U testuser -d testdb
```

```sql
-- Verify all 1000 rows restored
SELECT COUNT(*) FROM test_data;
-- Expected: 1000 ✅

-- Sample restored data
SELECT * FROM test_data LIMIT 5;

-- Check timestamps preserved
SELECT MIN(created_at), MAX(created_at) FROM test_data;

\q
```

## Success Criteria

- ✅ PostgreSQL deployed with Longhorn storage
- ✅ 1000 test rows created
- ✅ Manual backup completed
- ✅ Backup visible in MinIO
- ✅ Volume deleted successfully
- ✅ Volume restored from backup
- ✅ PV/PVC bound to restored volume
- ✅ PostgreSQL started with restored data
- ✅ All 1000 rows verified (100% data integrity)

## Cleanup

```bash
# Remove test application
kubectl delete namespace test-backups

# Remove PV if still exists
kubectl delete pv postgres-data-pv

# Delete backups from Longhorn UI or MinIO
```

## RTO/RPO

- **RTO (Recovery Time Objective)**: 10-15 minutes for single volume restore
- **RPO (Recovery Point Objective)**: Last backup (max 24 hours with daily backups)

## Notes

- This is a **test database only** - not for production data
- Backups are stored in MinIO: `s3://longhorn-backups@eu-west-1/`
- Recurring backups run automatically (daily at 2 AM, weekly Sunday 3 AM)
- Snapshots cleaned up daily at 6 AM

## Related Documentation

- [TODO.md Phase 3](../../TODO.md) - Complete testing workflow
- [Longhorn Backup Guide](https://longhorn.io/docs/1.10.0/snapshots-and-backups/backup-and-restore/)
- [Longhorn Restore StatefulSet](https://longhorn.io/docs/1.10.0/snapshots-and-backups/backup-and-restore/restore-statefulset/)
