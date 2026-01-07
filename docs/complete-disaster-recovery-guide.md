# Complete Disaster Recovery Guide

**Last Updated**: 2026-01-07
**Status**: Simplified workflow - verified end-to-end
**Recovery Scenario**: Complete K3s cluster loss with MinIO backups intact

## Quick Reference

Complete cluster rebuild from scratch in 4 commands:

```bash
make verify-backups    # 1. Check MinIO has backups
make k3s-teardown      # 2. Remove cluster completely
make k3s               # 3. Rebuild + restore (interactive pause for manual restore)
make apps-deploy-all   # 4. Deploy all applications
```

**Total time**: ~20-30 minutes
**Manual steps**: 1 (Longhorn UI system restore)
**Prerequisites**: MinIO accessible, Ansible configured, SSH access to nodes

---

## Overview

This guide documents the streamlined disaster recovery process for rebuilding the entire K3s cluster from Longhorn backups stored in MinIO.

**What gets restored**:
- K3s cluster configuration
- All Longhorn volumes and data
- Application configurations
- Backup job assignments

**What you need**:
- MinIO accessible at https://minio.jardoole.xyz
- Ansible environment on management machine
- SSH access to all cluster nodes
- Git repository with current configurations

---

## Step 1: Verify MinIO Backups

**Purpose**: Confirm backups exist before destroying cluster

```bash
make verify-backups
```

**What this checks**:
- MinIO service is accessible at https://minio.jardoole.xyz
- Longhorn system backups exist in MinIO
- Shows 5 most recent backup dates

**Expected output**:
```
✅ MinIO is accessible
📋 Checking for Longhorn system backups...
✅ System backups found (showing 5 most recent):
   2026-01-04 02:00:15 - backup-xxx.zip
   2025-12-28 02:00:12 - backup-xxx.zip
   2025-12-21 02:00:09 - backup-xxx.zip
   ...
✅ Backup verification complete - safe to proceed with recovery
```

**What happens if no backups**:
```
❌ ERROR: No system backups found in MinIO!
   Expected location: longhorn-backups/backups/longhorn-system-backup/
   Cannot proceed with disaster recovery without backups.
```

**Critical**: If this command fails, DO NOT proceed with teardown! You must have system backups to recover your data.

---

## Step 2: Teardown K3s Cluster

**Purpose**: Completely remove existing K3s installation

```bash
make k3s-teardown
```

**Duration**: 2-5 minutes

**What this does**:
- Stops K3s service on all nodes
- Removes K3s binaries and data
- Cleans up etcd cluster data
- Removes container images
- Cleans network configurations

**Expected output**:
```
TASK [Stop K3s service] ********************************************************
changed: [pi-cm5-1]
changed: [pi-cm5-2]
changed: [pi-cm5-3]

TASK [Run K3s uninstall script] ************************************************
changed: [pi-cm5-1]
...
```

**Verification** (optional):
```bash
uv run ansible control_plane -a "systemctl status k3s"
# Should show: "Unit k3s.service could not be found"
```

---

## Step 3: Rebuild K3s Cluster with Longhorn

**Purpose**: Deploy fresh K3s cluster and restore Longhorn volumes

```bash
make k3s
```

**Duration**: 10-15 minutes (plus manual restore time)

### What happens automatically:

**Phase 1-3**: K3s Cluster Deployment
- Installs K3s v1.34.1+k3s1 HA cluster (3 control plane + 1 worker)
- Configures embedded etcd cluster with new IP addresses
- Deploys CoreDNS, Traefik, metrics server
- Updates your local kubeconfig

**Phase 4**: Longhorn Deployment
- Installs Longhorn v1.10.0 storage system
- Configures MinIO backup target
- Creates recurring backup jobs (daily, weekly, system backups)
- **Pauses for manual system restore** ⚠️

### Interactive Pause - Manual Action Required

The script will pause and display:

```
═══════════════════════════════════════════════════════════════════════════════
⚠️  MANUAL ACTION REQUIRED - Longhorn System Restore (Disaster Recovery Only)
═══════════════════════════════════════════════════════════════════════════════

This step is ONLY needed if you are performing disaster recovery from backups.
If this is a fresh installation, simply press ENTER to continue.

DISASTER RECOVERY INSTRUCTIONS:
───────────────────────────────────────────────────────────────────────────────

1. Open Longhorn UI in your browser:
   → https://longhorn.jardoole.xyz

2. Navigate to "System Backup" in the left menu

3. Click "Restore Latest Backup" button
   (Or select a specific backup date if needed)

4. Wait for system restore to complete
   - This typically takes 1-2 minutes
   - The UI will show "Restore completed successfully"

5. DO NOT manually restore individual volumes
   - Volume restoration will be automated after this step

═══════════════════════════════════════════════════════════════════════════════

When ready to continue:
- Fresh installation: Press ENTER now
- After system restore: Press ENTER when restore is complete

═══════════════════════════════════════════════════════════════════════════════
```

### Manual System Restore Steps:

1. **Open Longhorn UI**: https://longhorn.jardoole.xyz

2. **Go to System Backup**:
   - Click **"Backup"** in top menu
   - Click **"System Backup"** tab

3. **Restore Latest Backup**:
   - Find the most recent backup (check date from Step 1)
   - Click three dots (⋮) next to backup
   - Select **"Restore"**
   - Wait for "Restore completed successfully" message (~1-2 minutes)

4. **Press ENTER** in the terminal to continue

### What happens after you press ENTER:

**Automatic Volume Recovery**:
- Script finds all restored Longhorn volumes
- Clears old PV claimRef bindings
- Creates PVCs for each volume
- Waits for automatic PV→PVC binding
- Verifies all volumes are bound correctly

**Expected output**:
```
TASK [Clear claimRef from Released PVs] ****************************************
changed: [pi-cm5-1]

TASK [Create PVCs for restored volumes] ****************************************
changed: [pi-cm5-1] => (item=media-stack-data)
changed: [pi-cm5-1] => (item=jellyfin-config)
...

✓ All volumes recovered and bound
```

**Cluster Ready Status**:
```
Phase 4 Complete: Storage Systems (Longhorn)
============================================
✓ Longhorn 1.10.0 installed in longhorn-system namespace
✓ Storage classes available
✓ All volumes restored and bound
✓ Backup jobs configured

Access Longhorn UI: https://longhorn.jardoole.xyz

Ready for application deployment!
```

---

## Step 4: Deploy Applications

**Purpose**: Restore all applications using existing data volumes

```bash
make apps-deploy-all
```

**Duration**: 5-10 minutes

**What this deploys**:
- All applications defined in `apps/` directory
- Each app binds to its existing PVC (no new volumes created)
- All historical data preserved

**Expected output**:
```
TASK [Deploy app: jellyfin] ****************************************************
changed: [pi-cm5-1]

TASK [Deploy app: radarr] ******************************************************
changed: [pi-cm5-1]
...

All applications deployed successfully
```

**Verification**:
```bash
# Check all pods are running
kubectl get pods --all-namespaces

# Check all PVCs are bound
kubectl get pvc --all-namespaces

# List all application endpoints
kubectl get ingress --all-namespaces
```

---

## Post-Recovery Verification

After deployment completes, verify everything is working:

### 1. Check Cluster Health

```bash
# Verify all nodes are Ready
kubectl get nodes -o wide

# Check all pods are Running
kubectl get pods --all-namespaces | grep -v Running | grep -v Completed
# Should show only header (no stuck pods)

# Verify storage system
kubectl get pv
kubectl get pvc --all-namespaces
```

### 2. Test Application Access

Visit each application and verify:
- Application loads correctly
- Historical data is present
- Configurations are intact

Common applications:
- Longhorn UI: https://longhorn.jardoole.xyz
- Jellyfin: https://jellyfin.jardoole.xyz
- Radarr: https://radarr.jardoole.xyz
- Sonarr: https://sonarr.jardoole.xyz

### 3. Verify Backup Jobs

```bash
# Check recurring jobs exist
kubectl get recurringjobs.longhorn.io -n longhorn-system

# Verify volumes have backup jobs assigned
kubectl get volumes.longhorn.io -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
JOBS:.metadata.labels."recurring-job-group\.longhorn\.io/default"

# Should show "enabled" for all volumes, not blank
```

**Expected recurring jobs**:
- `daily-backup` - Daily at 2 AM (retain 2 days)
- `weekly-backup` - Sunday at 3 AM (retain 2 weeks)
- `snapshot-cleanup` - Cleanup old snapshots
- `weekly-system-backup` - Full system backup weekly

### 4. Monitor First Backup Run

Wait for the next scheduled backup time (2 AM daily or 3 AM Sunday) and verify:

```bash
# Check backup status in Longhorn UI
# → Backup tab → Should show new backups with today's date

# Or check via kubectl
kubectl get backups.longhorn.io -n longhorn-system
```

---

## Recovery Metrics

**Measured during 2026-01-06 recovery**:
- **Total time**: ~25 minutes (including manual restore)
- **Manual steps**: 1 (Longhorn UI system restore, ~2 minutes)
- **Automated steps**: Everything else
- **Data loss**: None (when backup is recent)
- **Errors encountered**: None (after fixes applied)

**Breakdown**:
- Step 1 (verify-backups): 1 minute
- Step 2 (k3s-teardown): 3 minutes
- Step 3 (k3s rebuild + Longhorn + restore): 15 minutes
  - Manual restore: 2 minutes
  - Automatic volume recovery: 1 minute
- Step 4 (apps-deploy-all): 6 minutes

---

## Lessons Learned

**Issues discovered and fixed during January 2026 recovery**:

### Issue 1: Backup Jobs Not Restored ⚠️

**Problem**: After system restore, volumes had NO backup jobs assigned
- Setting `restoreVolumeRecurringJobs` defaulted to `false`
- Restored volumes were unprotected until manually configured

**Fix Applied** (apps/longhorn/values.yml:171):
```yaml
defaultSettings:
  restoreVolumeRecurringJobs: "true"  # CRITICAL for DR
```

**Additional Fix** (apps/longhorn/postinstall.yml:104-115):
```yaml
# Automatically assign backup jobs to ALL volumes via labels
metadata:
  labels:
    recurring-job-group.longhorn.io/default: enabled
```

**Verification**: All volumes now automatically get backup jobs after restore

### Issue 2: Missing PVs for Old Volumes

**Problem**: Volumes last backed up >2 months ago didn't get PVs auto-created
- System backup from Nov 16 had incomplete metadata for 2 volumes
- Manual PV creation was required

**Lesson**: Ensure ALL volumes are backed up regularly
- System backups only retain recent volume metadata
- Volume data backups contain the actual data
- Both are needed for complete recovery

**Prevention**:
- Weekly system backups now configured
- All volumes have recurring backup jobs
- Monitor backup status in Longhorn UI

### Issue 3: 867GB Data Loss Discovery

**What happened**: 1TB media volume restored from November, not January
- Most recent volume backup was from Nov 16 (2 months old)
- 867GB of downloaded movies between Nov-Jan lost
- Orphaned replica existed on disk but was in Longhorn snapshot chain format

**Why recovery failed**:
- Longhorn stores volumes as differential snapshot chains
- Cannot simply mount the raw data without Longhorn engine
- Manual recovery would require deep Longhorn internals knowledge

**Lessons**:
1. Volume backups != System backups (both needed!)
2. Check backup recency BEFORE starting recovery
3. Verify backup jobs are actually running (not just configured)
4. Data in Longhorn format requires Longhorn to read

**Prevention Applied**:
- `restoreVolumeRecurringJobs: "true"` ensures jobs are assigned
- Postinstall playbook assigns default backup group to ALL volumes
- Weekly system backups capture current volume metadata

### Issue 4: Network Change Resilience

**Original Problem**: Hardcoded `192.168.0.x` IP in kubeconfig-update
- Router switch changed subnet to `192.168.1.x`
- kubeconfig update failed until manually edited

**Fix Applied** (Makefile:108):
```bash
# Changed from hardcoded IP to hostname
sed 's|https://127.0.0.1:6443|https://pi-cm5-1:6443|'
```

**Benefit**: Recovery now works regardless of subnet changes

---

## Troubleshooting

### Problem: MinIO not accessible

**Error**: `curl: (7) Failed to connect to minio.jardoole.xyz`

**Solution**:
```bash
# Check DNS resolution
dig minio.jardoole.xyz

# Check if pi-cm5-4 (NAS) is online
ping pi-cm5-4

# Verify MinIO service on NAS
ssh pi-cm5-4 "systemctl status minio"

# Check firewall rules
ssh pi-cm5-4 "sudo iptables -L | grep 9000"
```

### Problem: No system backups found in MinIO

**Error**: Empty `longhorn-backups/backups/longhorn-system-backup/` directory

**Recovery options**:
1. **If you have recent volume backups**: You can manually recreate PVs
2. **If no backups at all**: Fresh install required (data loss)

**Prevention**: Verify weekly system backups are running

### Problem: System restore hangs at "In Progress"

**Symptoms**: Longhorn UI shows restore stuck for >5 minutes

**Solution**:
```bash
# Check Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100

# Check backup target connectivity
kubectl exec -n longhorn-system deploy/longhorn-manager -- \
  curl -v s3://longhorn-backups@eu-west-1/

# Restart stuck restore
kubectl delete backuptarget -n longhorn-system --all
make app-upgrade APP=longhorn
```

### Problem: Volumes show "Degraded" after restore

**Symptoms**: Red status in Longhorn UI, pods can't mount volumes

**Solution**:
```bash
# Check replica status
kubectl get replicas.longhorn.io -n longhorn-system

# Verify storage capacity
kubectl exec -n longhorn-system daemonset/longhorn-manager -- df -h /var/lib/longhorn

# Force replica rebuild (if needed)
# → Longhorn UI → Volume → three dots → "Salvage" → "Rebuild"
```

### Problem: PVC stays in "Pending" state

**Symptoms**: `kubectl get pvc` shows Pending for >5 minutes

**Solution**:
```bash
# Check PVC events
kubectl describe pvc <pvc-name> -n <namespace>

# Verify PV exists and is Available
kubectl get pv | grep <volume-name>

# Check if PV has old claimRef (should be cleared by recover-volumes)
kubectl get pv <pv-name> -o yaml | grep claimRef

# Manually clear claimRef if needed
kubectl patch pv <pv-name> -p '{"spec":{"claimRef":null}}'
```

### Problem: Application pod stuck in CrashLoopBackOff

**Symptoms**: Pod repeatedly restarting after restore

**Common causes**:
1. Volume contains corrupted config from old backup
2. Application expects different file permissions
3. Volume data incompatible with new application version

**Solution**:
```bash
# Check pod logs
kubectl logs -n <namespace> <pod-name>

# Check previous crash logs
kubectl logs -n <namespace> <pod-name> --previous

# Verify PVC is bound
kubectl get pvc -n <namespace>

# Check volume permissions (if app runs as specific UID)
kubectl exec -n <namespace> <pod-name> -- ls -la /data

# Nuclear option: Delete PVC, restore from earlier backup
kubectl delete pvc <pvc-name> -n <namespace>
# Restore older backup in Longhorn UI
make app-deploy APP=<app-name>
```

---

## Related Documentation

- [Longhorn Disaster Recovery](longhorn-disaster-recovery.md) - Detailed Longhorn backup/restore procedures
- [App Deployment Guide](app-deployment-guide.md) - Application deployment workflow
- [Helm Standards](helm-standards.md) - Chart configuration standards
- [Project Structure](project-structure.md) - Repository organization

---

## Emergency Contacts

**If this guide fails**:
1. Check Longhorn documentation: https://longhorn.io/docs/
2. Review K3s HA setup: https://docs.k3s.io/datastore/ha-embedded
3. Consult project commit history for recent changes:
   ```bash
   git log --oneline --graph --all | head -20
   ```

**Last successful recovery**: 2026-01-07 (full cluster rebuild from 2026-01-04 backup)
