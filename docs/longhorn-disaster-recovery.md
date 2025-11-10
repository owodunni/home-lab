# Longhorn Disaster Recovery Guide

Comprehensive guide for recovering from data loss or cluster failures using Longhorn backups.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Backup Strategy](#backup-strategy)
3. [Recovery Scenarios](#recovery-scenarios)
4. [Recovery Procedures](#recovery-procedures)
5. [Troubleshooting](#troubleshooting)
6. [Recovery Objectives](#recovery-objectives)

---

## Architecture Overview

### Backup Storage Design

**Critical Design Decision**: MinIO S3 storage runs **outside the Kubernetes cluster** on dedicated NAS node (pi-cm5-4).

```
┌─────────────────────────────────────────────────────────┐
│ K3s Cluster (pi-cm5-1, pi-cm5-2, pi-cm5-3)            │
│                                                         │
│  ┌─────────────┐      ┌──────────────┐                │
│  │ Application │─────▶│ PVC (2Gi)    │                │
│  │   Pod       │      └──────────────┘                │
│  └─────────────┘             │                         │
│                               │                         │
│                      ┌────────▼──────────┐             │
│                      │ Longhorn Volume   │             │
│                      │ (pvc-abc123)      │             │
│                      └────────┬──────────┘             │
│                               │                         │
│                      ┌────────▼──────────┐             │
│                      │ Local Snapshots   │             │
│                      │ (on Longhorn disk)│             │
│                      └────────┬──────────┘             │
│                               │                         │
└───────────────────────────────┼─────────────────────────┘
                                │ S3 Backup (HTTPS)
                                │
                      ┌─────────▼──────────┐
                      │ MinIO (pi-cm5-4)   │
                      │ External Storage   │
                      │                    │
                      │ /longhorn-backups/ │
                      │  ├─ backups/       │
                      │  └─ system-backups/│
                      └────────────────────┘
```

**Why This Matters**:
- **Cluster failure** → MinIO survives with all backups intact
- **MinIO failure** → Cluster continues running with local snapshots
- **Complete rebuild** → Restore entire cluster state from external MinIO

### Backup Types

| Type | Stores | Frequency | Retention | Purpose |
|------|--------|-----------|-----------|---------|
| **Snapshot** | Local only | Per-PVC settings | Varies | Fast rollback, crash recovery |
| **Volume Backup** | MinIO S3 | Daily 2 AM, Weekly Sun 3 AM | 7 daily, 4 weekly | Volume data protection |
| **System Backup** | MinIO S3 | Weekly Sun 4 AM | 4 weekly | Cluster config, bulk restore |

---

## Backup Strategy

### Automated Recurring Jobs

All backups run automatically via Longhorn RecurringJob CRDs:

```yaml
# Daily volume backups (2:00 AM)
daily-backup:
  cron: "0 2 * * *"
  task: backup
  retain: 7

# Weekly volume backups (Sunday 3:00 AM)
weekly-backup:
  cron: "0 3 * * 0"
  task: backup
  retain: 4

# Snapshot cleanup (6:00 AM)
snapshot-cleanup:
  cron: "0 6 * * *"
  task: snapshot-cleanup
  retain: 1

# Weekly system backups (Sunday 4:00 AM)
weekly-system-backup:
  cron: "0 4 * * 0"
  task: system-backup
  retain: 4
  volume-backup-policy: if-not-present
```

**Configuration**: `apps/longhorn/prerequisites.yml`

### What Gets Backed Up

**Volume Backups**:
- Actual volume data (filesystem blocks)
- Stored in MinIO: `s3://longhorn-backups/backups/<volume-name>/`
- Size: Varies by volume usage

**System Backups**:
- All Longhorn CRDs (Volume, RecurringJob, Settings, etc.)
- Volume metadata (size, replicas, StorageClass)
- Backup target configuration
- Stored in MinIO: `s3://longhorn-backups/system-backups/system-backup-<timestamp>.zip`
- Size: Usually < 1MB (metadata only)

**What Is NOT Backed Up**:
- Kubernetes resources (Deployments, Services, ConfigMaps)
- Application Helm charts (stored in `apps/` directory in git)
- K3s cluster configuration (reproducible from Ansible playbooks)

---

## Recovery Scenarios

### Scenario 1: Accidental File Deletion (Single Volume)

**Impact**: User deleted files inside a pod
**RTO**: 5-10 minutes
**Requires**: Recent volume backup

### Scenario 2: Volume Corruption

**Impact**: Filesystem corrupted, pod crash-looping
**RTO**: 10-15 minutes
**Requires**: Recent volume backup

### Scenario 3: Complete Cluster Failure

**Impact**: All nodes lost, cluster unrecoverable
**RTO**: 30-45 minutes
**Requires**: System backup + volume backups + MinIO accessible

### Scenario 4: MinIO Data Loss

**Impact**: All backups lost
**RTO**: Not recoverable (no offsite backups)
**Mitigation**: Regular verification, consider offsite replication

---

## Recovery Procedures

### Procedure 1: Restore Single Volume

**When**: Recover one volume without affecting others

**Steps**:

1. **Identify the volume**:
   ```bash
   kubectl get pvc -n <namespace>
   kubectl get volumes.longhorn.io -n longhorn-system
   ```

2. **Scale down application**:
   ```bash
   kubectl scale deployment <name> -n <namespace> --replicas=0
   # OR for StatefulSet:
   kubectl scale statefulset <name> -n <namespace> --replicas=0
   ```

3. **Delete PVC** (this detaches and deletes the volume):
   ```bash
   kubectl delete pvc <pvc-name> -n <namespace>
   ```

4. **Restore from backup via Longhorn UI**:
   - Navigate to: Longhorn UI → **Backup** tab
   - Find backup for the volume (search by name or date)
   - Click backup → **Restore**
   - Volume name: `<original-volume-name>` (e.g., `pvc-abc123`)
   - Wait for restore to complete (~2-5 minutes depending on size)

5. **Create PV for restored volume**:
   ```yaml
   # saved as restore-pv.yml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: <volume-name>-restored-pv
   spec:
     capacity:
       storage: <size>  # Match original (e.g., 2Gi)
     volumeMode: Filesystem
     accessModes:
       - ReadWriteOnce
     persistentVolumeReclaimPolicy: Retain
     storageClassName: longhorn
     csi:
       driver: driver.longhorn.io
       fsType: ext4
       volumeHandle: <longhorn-volume-name>  # From step 4
       volumeAttributes:
         numberOfReplicas: "1"
         staleReplicaTimeout: "30"
   ```

   Apply:
   ```bash
   kubectl apply -f restore-pv.yml
   ```

6. **Create PVC bound to PV**:
   ```yaml
   # saved as restore-pvc.yml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: <original-pvc-name>  # Must match original!
     namespace: <original-namespace>
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: <size>  # Match PV
     storageClassName: longhorn
     volumeName: <volume-name>-restored-pv  # From step 5
   ```

   Apply:
   ```bash
   kubectl apply -f restore-pvc.yml
   kubectl get pvc -n <namespace>  # Verify "Bound" status
   ```

7. **Scale up application**:
   ```bash
   kubectl scale deployment <name> -n <namespace> --replicas=1
   # Wait for pod to start
   kubectl wait --for=condition=ready pod/<pod-name> -n <namespace> --timeout=120s
   ```

8. **Verify data**:
   ```bash
   kubectl exec -it <pod-name> -n <namespace> -- ls -la /data
   # Application-specific verification
   ```

**Example - PostgreSQL**:

See `apps/postgres-test/README.md` for complete PostgreSQL restore example with SQL verification.

---

### Procedure 2: Full Cluster Rebuild

**When**: Cluster destroyed, need to restore all volumes and apps

**Prerequisites**:
- MinIO accessible from your laptop: `curl -I https://minio.jardoole.xyz`
- System backup exists: Check Longhorn UI → System Backup tab
- All apps configured in git: `apps/` directory up to date

**Steps**:

#### 1. Teardown (if cluster still exists)

```bash
make k3s-teardown
```

**Result**: K3s completely removed, MinIO untouched

#### 2. Rebuild Infrastructure

```bash
make k3s
```

**What this deploys**:
- K3s v1.34.1 (3-node HA)
- Helm
- cert-manager (TLS certificates)
- Longhorn (storage system)
- Platform foundation (namespaces, quotas, network policies)

**Time**: ~15-20 minutes

**Verify**:
```bash
kubectl get nodes  # All nodes Ready
kubectl get pods -n longhorn-system  # All Running
```

#### 3. Verify Longhorn Backup Target

```bash
# Check backup target connected
kubectl get settings.longhorn.io backup-target -n longhorn-system -o yaml
```

**Expected**:
```yaml
value: s3://longhorn-backups@eu-west-1/
```

**If not configured**: Backup target is defined in `group_vars/longhorn/main.yml` and should be auto-configured. If missing, re-run:
```bash
make app-upgrade APP=longhorn
```

#### 4. Restore System Backup (1 Manual Step)

**Via Longhorn UI**:
1. Open Longhorn UI: `https://longhorn.jardoole.xyz`
2. Navigate to: **System Backup** tab
3. Find latest system backup (e.g., `system-backup-20250308-040015`)
4. Click backup → **Restore**
5. Wait for restore to complete (~1-2 minutes)

**What this does**:
- Recreates all Longhorn Volume CRDs
- Restores volume metadata (size, replicas, labels)
- Restores RecurringJob definitions
- Restores Longhorn settings

**Verify**:
```bash
kubectl get volumes.longhorn.io -n longhorn-system
# Should show all volumes from pre-teardown state

kubectl get pv
# Volumes will be in "Released" state (orphaned, need rebinding)
```

#### 4.5. Automated Volume Recovery (NEW)

**Problem**: System Backup restores volume data but leaves PVs in "Released" state. Without this step, `make apps-deploy-all` would create NEW empty volumes instead of using restored data.

**Solution**: Automated playbook rebinds Released PVs:

```bash
make recover-volumes
```

**What this does**:
1. Scans for all Released PVs
2. Clears claimRef from each PV (makes them Available)
3. Recreates PVCs with original names
4. Waits for automatic binding to complete

**Time**: ~1-2 minutes

**Output example**:
```
═══════════════════════════════════════════════════════
Volume Recovery Summary
═══════════════════════════════════════════════════════
Total PVs: 8
Released PVs to recover: 6
═══════════════════════════════════════════════════════
  ✓ media/jellyfin-config (2Gi)
  ✓ media/radarr-config (1Gi)
  ✓ media/sonarr-config (1Gi)
  ✓ media/prowlarr-config (500Mi)
  ✓ media/qbittorrent-config (500Mi)
  ✓ media/media-stack-data (1Ti)
═══════════════════════════════════════════════════════
```

**Verify**:
```bash
kubectl get pv
# All PVs should now show "Bound" status

kubectl get pvc --all-namespaces
# PVCs created and bound to restored volumes
```

**Manual Alternative** (if playbook fails):
```bash
# 1. Clear claimRefs
for pv in $(kubectl get pv -o json | jq -r '.items[] | select(.status.phase=="Released") | .metadata.name'); do
  kubectl patch pv $pv --type json -p '[{"op": "remove", "path": "/spec/claimRef"}]'
done

# 2. Manually create PVCs (see Procedure 1 for details)
```

#### 5. Redeploy Applications

```bash
make apps-deploy-all
# OR individual apps:
# make app-deploy APP=postgres-test
# make app-deploy APP=kube-prometheus-stack
```

**What happens now**:
1. App deployment looks for existing PVC (created in step 4.5)
2. Finds PVC already bound to restored volume
3. Pod starts immediately with existing data intact
4. No new volumes created, no data loss

**Time**: ~5-10 minutes

**Verify**:
```bash
kubectl get pvc --all-namespaces
# All PVCs should show "Bound" status

kubectl get pods --all-namespaces
# All pods should reach "Running" state
```

#### 6. Verify Data Integrity

**PostgreSQL example**:
```bash
kubectl exec -it postgres-test-postgresql-0 -n test-backups -- \
  bash -c 'PGPASSWORD=$(cat /opt/bitnami/postgresql/secrets/password) psql -U testuser -d testdb -c "SELECT COUNT(*) FROM test_data;"'
```

**Expected**: Original row count preserved (e.g., 1000 rows)

**Prometheus/Grafana**:
- Check dashboards load correctly
- Verify historical metrics preserved
- Check alerting rules

**Other apps**: Application-specific verification

#### 7. Verify Backup Jobs Restored

```bash
kubectl get recurringjobs.longhorn.io -n longhorn-system
```

**Expected**: 4 recurring jobs
- `daily-backup`
- `weekly-backup`
- `snapshot-cleanup`
- `weekly-system-backup`

**If missing**: RecurringJobs are part of System Backup and should be restored. If not, redeploy:
```bash
make app-upgrade APP=longhorn
```

---

## Troubleshooting

### Issue: Backup Target Shows "Red X" After Rebuild

**Symptoms**: Longhorn UI → Settings → Backup Target shows error

**Causes**:
1. MinIO not accessible (network issue)
2. Credentials incorrect
3. Bucket doesn't exist

**Fix**:

1. **Check MinIO accessibility**:
   ```bash
   curl -I https://minio.jardoole.xyz
   # Should return HTTP 200 or 403
   ```

2. **Check credentials**:
   ```bash
   kubectl get secret longhorn-backup-target-credential -n longhorn-system -o yaml
   # Verify AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set
   ```

3. **Verify bucket exists**:
   ```bash
   ssh alexanderp@pi-cm5-4
   sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/
   # Should show backups/ and system-backups/ directories
   ```

4. **Re-apply backup target configuration**:
   ```bash
   make app-upgrade APP=longhorn
   ```

---

### Issue: PVC Stuck in "Pending" After Restore

**Symptoms**: PVC shows `Pending` status, pod can't start

**Causes**:
1. No matching PV exists
2. Volume name mismatch
3. StorageClass mismatch

**Fix**:

1. **Check for available PVs**:
   ```bash
   kubectl get pv
   # Look for "Available" PVs
   ```

2. **Check volume exists in Longhorn**:
   ```bash
   kubectl get volumes.longhorn.io -n longhorn-system
   # Find volume with matching name
   ```

3. **Check PVC spec matches PV**:
   ```bash
   kubectl describe pvc <pvc-name> -n <namespace>
   # Verify storageClassName and volumeName
   ```

4. **If volume restored with different name**, update PVC:
   ```bash
   kubectl edit pvc <pvc-name> -n <namespace>
   # Update spec.volumeName to match actual Longhorn volume
   ```

---

### Issue: Restored Data is Old/Missing

**Symptoms**: Application shows outdated data or missing recent changes

**Causes**:
1. Restored from old backup
2. Backup didn't include latest changes
3. Application had uncommitted transactions

**Fix**:

1. **Check backup timestamp**:
   ```bash
   # In Longhorn UI → Backup tab
   # Look at "Created" column for backup
   ```

2. **Check when last backup ran**:
   ```bash
   kubectl get recurringjobs.longhorn.io daily-backup -n longhorn-system -o yaml
   # Check status.lastRun
   ```

3. **Verify backup frequency is sufficient** for your RPO requirements
   - Current: Daily backups → max 24 hours data loss
   - If insufficient, increase backup frequency (edit `apps/longhorn/prerequisites.yml`)

4. **For critical applications**, consider:
   - More frequent backups (e.g., every 6 hours)
   - Application-level backups (e.g., pg_dump for PostgreSQL)
   - Longhorn snapshots for faster point-in-time recovery

---

### Issue: System Backup Restore Fails

**Symptoms**: System Backup restore shows error in Longhorn UI

**Causes**:
1. Incompatible Longhorn versions
2. Corrupted backup file
3. Insufficient resources

**Fix**:

1. **Check Longhorn version compatibility**:
   ```bash
   kubectl get settings.longhorn.io longhorn-version -n longhorn-system -o yaml
   # System backup from Longhorn 1.10.x should restore to 1.10.x
   ```

2. **Check backup file integrity**:
   ```bash
   ssh alexanderp@pi-cm5-4
   sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/system-backups/
   # Verify file size > 0
   ```

3. **Check Longhorn logs**:
   ```bash
   kubectl logs -n longhorn-system deployment/longhorn-driver-deployer
   kubectl logs -n longhorn-system daemonset/longhorn-manager
   ```

4. **Verify MinIO credentials not expired**:
   ```bash
   kubectl get secret longhorn-backup-target-credential -n longhorn-system -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d
   # Should match vault_longhorn_backup_password from group_vars
   ```

---

## Recovery Objectives

### RTO (Recovery Time Objective)

| Scenario | RTO | Hands-On Time | Automated |
|----------|-----|---------------|-----------|
| Single volume restore | 10-15 min | 5 min | Partial |
| Single app restore | 15-20 min | 5 min | Mostly |
| Full cluster rebuild | 30-45 min | 5 min | Mostly (1 UI click) |

**Breakdown (Full Cluster Rebuild)**:
- Teardown: 5 minutes (automated)
- Rebuild K3s: 15-20 minutes (automated)
- System Restore: 1-2 minutes (1 manual UI click)
- Redeploy apps: 5-10 minutes (automated)
- Verification: 5-10 minutes (manual checks)

**Bottlenecks**:
- K3s deployment time (largest component)
- Application startup time (varies by app)

### RPO (Recovery Point Objective)

| Backup Type | Frequency | Max Data Loss |
|-------------|-----------|---------------|
| Daily volume backup | 2:00 AM daily | 24 hours |
| Weekly volume backup | 3:00 AM Sunday | 7 days |
| System backup | 4:00 AM Sunday | 7 days |

**For critical data**: Consider increasing backup frequency in `apps/longhorn/prerequisites.yml`:

```yaml
# Example: Every 6 hours instead of daily
critical-backup:
  cron: "0 */6 * * *"  # Every 6 hours
  task: backup
  retain: 28  # Keep 7 days of 6-hour backups
```

---

## Best Practices

### Backup Verification

**Weekly checks**:
```bash
# 1. Verify recurring jobs running
kubectl get recurringjobs.longhorn.io -n longhorn-system

# 2. Check recent backups exist
# Longhorn UI → Backup tab → Verify timestamps < 24 hours

# 3. Verify MinIO accessible
curl -I https://minio.jardoole.xyz

# 4. Check backup storage usage
ssh alexanderp@pi-cm5-4
sudo -u minio /usr/local/bin/mc du myminio/longhorn-backups/
```

**Quarterly restore tests**:
- Test single volume restore (non-production app)
- Verify data integrity after restore
- Document any issues or improvements

**Annual DR drill**:
- Full cluster rebuild test
- All apps restored
- Complete data verification
- Update RTO/RPO if needed

### Monitoring Backup Health

**Alert on**:
- Backup job failures (check Longhorn events)
- Backup target disconnected
- MinIO storage capacity > 80%
- Backups older than 48 hours

**Prometheus/Grafana queries** (if using kube-prometheus-stack):
- `longhorn_volume_backup_state` - Monitor backup completion
- `longhorn_backup_target_available` - Alert if target unreachable

---

## Limitations & Future Enhancements

### Current Limitations

1. **No offsite backups**: Backups stored only in local MinIO
   - **Risk**: Building fire, theft, hardware failure
   - **Mitigation**: MinIO on separate node, UPS power

2. **Manual System Backup restore**: Requires 1 UI click
   - **Current**: Minimal impact (30 seconds)
   - **Future**: Could automate via Longhorn API/kubectl

3. **No application-level backups**: Only volume backups
   - **Example**: PostgreSQL pg_dump not automated
   - **Mitigation**: Volume backups capture all data, but application-level backups provide additional safety

4. **No backup encryption**: Backups stored unencrypted in MinIO
   - **Risk**: If MinIO compromised, backups readable
   - **Mitigation**: Home lab acceptable risk, MinIO access controlled

### Future Enhancements

**Phase 7.1: Offsite Backup Replication**
- Replicate MinIO backups to cloud storage (S3, Backblaze B2)
- Implement 3-2-1 backup rule (3 copies, 2 media types, 1 offsite)
- Scheduled weekly sync via rclone

**Phase 7.2: Automated Verification**
- Playbook to verify backup integrity
- Automated restore tests in staging environment
- Slack/email notifications on backup failures

**Phase 7.3: Application-Level Backups**
- PostgreSQL: Automated pg_dump with point-in-time recovery
- Prometheus: Snapshot backups
- Grafana: Dashboard exports

---

## Related Documentation

- [TODO.md](../TODO.md) - Complete implementation roadmap (Phases 1-7)
- [apps/longhorn/README.md](../apps/longhorn/README.md) - Longhorn configuration details
- [apps/postgres-test/README.md](../apps/postgres-test/README.md) - PostgreSQL restore example
- [Longhorn Backup/Restore Official Docs](https://longhorn.io/docs/1.10.0/snapshots-and-backups/backup-and-restore/)
- [Longhorn System Backup](https://longhorn.io/docs/1.10.0/advanced-resources/system-backup-restore/)

---

## Support & Contact

**For issues**:
1. Check [Troubleshooting](#troubleshooting) section above
2. Review Longhorn logs: `kubectl logs -n longhorn-system <pod-name>`
3. Check Longhorn events: `kubectl get events -n longhorn-system --sort-by='.lastTimestamp'`
4. Consult official Longhorn documentation

**Ansible Playbooks**:
- K3s deployment: `playbooks/k3s/k3s-complete.yml`
- Longhorn deployment: `apps/longhorn/app.yml`
- Longhorn prerequisites: `apps/longhorn/prerequisites.yml`

**Quick Reference**:
```bash
# Deploy/upgrade Longhorn with backups
make app-deploy APP=longhorn
make app-upgrade APP=longhorn

# Check backup jobs
kubectl get recurringjobs.longhorn.io -n longhorn-system

# Full cluster rebuild
make k3s-teardown
make k3s
# Manual: Restore System Backup via Longhorn UI
make apps-deploy-all
```
