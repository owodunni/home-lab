# Longhorn Snapshot-Cleanup Explained

## Overview

The `snapshot-cleanup` recurring job is a critical maintenance task that prevents disk exhaustion on your worker nodes by removing old local snapshots.

## What snapshot-cleanup Does

**snapshot-cleanup** periodically purges snapshots that are:
- No longer needed for data integrity
- Marked as removable
- System-generated from automatic operations

**Important**: The `retain` parameter is automatically mutated to **0** by Longhorn for this task type, meaning it removes all eligible snapshots (it doesn't keep any).

## Snapshots vs Backups: Understanding the Difference

### Local Snapshots
- **Location**: `/var/lib/longhorn` on worker node (Beelink)
- **Purpose**: Point-in-time copies for quick local recovery
- **Lifecycle**: Created automatically, but NOT automatically deleted
- **Created by**:
  - Backup operations (daily/weekly backup jobs)
  - System operations (replica rebuilds)
  - CSI snapshot requests
  - Volume maintenance operations
- **Limitation**: Lost if worker node fails

### Remote Backups
- **Location**: `s3://longhorn-backups@eu-west-1/` (MinIO on pi-cm5-4)
- **Purpose**: Disaster recovery (survives cluster rebuild)
- **Retention**:
  - Daily backups: 7 days (runs at 2 AM)
  - Weekly backups: 4 weeks (runs Sunday 3 AM)
- **Safety**: External to K3s cluster, preserved during teardown

### Critical Distinction

**snapshot-cleanup does NOT delete your remote backups in MinIO!**

It only removes local snapshots on the worker node that have already been uploaded to MinIO or are no longer needed.

## Why Snapshots Accumulate Locally

Even though backups upload to MinIO, **local snapshots remain on disk** after backup completes. Here's why:

1. **Backup workflow**:
   - Daily backup at 2 AM creates snapshot
   - Snapshot data uploads to MinIO
   - **Snapshot stays on `/var/lib/longhorn`** (not auto-deleted)

2. **Automatic system snapshots**:
   - Replica failures trigger rebuild snapshots
   - Volume operations create temporary snapshots
   - CSI operations generate snapshots

3. **Result**: Without cleanup, snapshots accumulate continuously

## Why Once Daily at 6 AM?

### The Schedule
```
cron: "0 6 * * *"
```
Runs at: **06:00** (6 AM daily)

### The Rationale for Home Lab

1. **Post-backup cleanup**:
   - Daily backup runs at 2 AM → Cleanup at 6 AM (4 hours after)
   - Weekly backup runs Sunday 3 AM → Cleanup at 6 AM (3 hours after)
   - Cleans up all backup-created snapshots from previous 24 hours

2. **Snapshot limits are not a concern**:
   - Longhorn enforces 254 snapshots per volume (default)
   - Home lab creates ~1-2 snapshots/day per volume
   - **Time to hit limit**: 127+ days without any cleanup
   - Once-daily cleanup is more than sufficient

3. **Minimal system snapshot generation**:
   - Stable volumes in home lab rarely trigger system snapshots
   - Replica rebuilds are infrequent
   - No need for hourly or 4x daily cleanup

4. **Home lab vs Production**:
   - Production with dozens of volumes: May need hourly cleanup
   - Production with multi-daily backups: May need 4x daily cleanup
   - **Your setup**: Few volumes, daily backups → Once daily is optimal

## What Happens Without Regular Cleanup?

### Immediate Effects
- Snapshots accumulate on `/var/lib/longhorn`
- Disk usage grows continuously

### Critical Failures
1. **Storage exhaustion**: `/var/lib/longhorn` fills up completely
2. **Hit snapshot limits**: Reach max count (250) or max size
3. **Backup failures**: Daily/weekly backups fail because they can't create new snapshots
4. **Operations blocked**: Error: "You must delete snapshots before creating new ones"
5. **Volume issues**: Rebuilds and maintenance operations fail

### Recovery Required
Manual intervention needed to delete snapshots and free space - time-consuming and risky.

## Recommended Configuration

For `apps/longhorn/prerequisites.yml`:

```yaml
---
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: snapshot-cleanup
  namespace: longhorn-system
spec:
  cron: "0 6 * * *"        # Once daily at 6 AM
  task: snapshot-cleanup
  groups:
    - default              # Applies to all volumes
  retain: 1                # Ignored - Longhorn automatically sets to 0
  concurrency: 3           # Clean 3 volumes simultaneously
  labels:
    recurring-job: snapshot-cleanup
```

### Configuration Analysis

**Frequency**: Once daily at 6 AM - ✅ Optimal for home lab with daily backups

**Groups**: `default` - ✅ Applies to all volumes automatically

**Concurrency**: `3` - ✅ Good balance (cleanup multiple volumes in parallel without overloading)

**Retain**: Set to `1` but Longhorn ignores this and uses `0` - ✅ Expected behavior

## Best Practices

1. **Never disable snapshot-cleanup** - Critical for cluster health
2. **Monitor disk usage**: Check `/var/lib/longhorn` regularly
3. **Verify cleanup runs**: Longhorn UI → RecurringJob tab
4. **Once daily is sufficient** for home labs with stable volumes
5. **Understand retention**: Your MinIO backups (7 daily + 4 weekly) are separate and safe

## When to Increase Cleanup Frequency

Consider more frequent cleanup (hourly or 4x daily) if:

- **10+ volumes** with active workloads
- **Multiple backups per day** (hourly or every few hours)
- **High volume churn** (databases with heavy writes)
- **Frequent replica rebuilds** (unstable storage)
- **Snapshot warnings** in Longhorn UI
- **Moving to production** with critical workloads

For home lab with daily backups and few volumes, once daily is optimal.

## Summary

- **snapshot-cleanup** = Local housekeeping (removes old snapshots from worker disk)
- **Daily/weekly backups** = Remote disaster recovery (safe in MinIO)
- **Once daily at 6 AM** = Optimal for home lab with daily backups
- **Recommended configuration** = Prevents disk exhaustion without over-engineering

Your remote backups in MinIO are completely safe - snapshot-cleanup only manages local worker node disk space.

**Key takeaway**: Don't over-engineer. Home labs don't need production-level cleanup frequencies.

## Related Documentation

- **Longhorn Recurring Backups**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/scheduling-backups-and-snapshots/
- **Your TODO.md**: Phase 2, lines 142-146 (snapshot cleanup rationale)
- **Backup Target Setup**: `apps/longhorn/prerequisites.yml` (BackupTarget CRD)
