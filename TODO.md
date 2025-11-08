# TODO - Longhorn Backup System Verification

**Status**: Automation complete, awaiting manual verification of backup workflows.

**Reference**: See [Longhorn Disaster Recovery Guide](docs/longhorn-disaster-recovery.md) for complete procedures.

---

## Pending Manual Verification

### Phase 2: Verify Recurring Backups ⏳

**What**: Confirm automated backup jobs are running as scheduled.

**When**: After deploying recurring jobs configuration.

**Tasks**:

- [ ] **Deploy recurring jobs**
  ```bash
  make app-upgrade APP=longhorn
  ```

- [ ] **Verify jobs created**
  ```bash
  kubectl get recurringjobs.longhorn.io -n longhorn-system
  ```
  Expected: 4 jobs (daily-backup, weekly-backup, snapshot-cleanup, weekly-system-backup)

- [ ] **Verify jobs assigned to volumes**
  - Longhorn UI → Volume tab → Select volume → Recurring Job Schedule
  - Expected: All jobs auto-assigned (via `groups: [default]`)

- [ ] **Monitor first scheduled backup (Week-long monitoring)**
  - **When**: After 2:00 AM next day
  - **Check**: Longhorn UI → Backup tab
  - **Expected**: New backup with label `recurring-job=daily-backup`
  - **Verify MinIO**:
    ```bash
    ssh alexanderp@pi-cm5-4 "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/"
    ```
  - Monitor backup creation over next week

---

### Phase 3: Test Single Volume Restore 🧪

**What**: Prove backup/restore workflow works with test PostgreSQL database.

**When**: After Phase 2 complete and first backup runs.

**Tasks**:

- [ ] **Add vault secret** (if not already done)
  ```bash
  uv run ansible-vault edit group_vars/all/vault.yml
  # Add: vault_postgres_test_password: "8q5kHwQoxrKn9gbSWSPwgEcyeqi/I9Fe"
  ```

- [ ] **Deploy PostgreSQL test app**
  ```bash
  make app-deploy APP=postgres-test
  ```

- [ ] **Generate test data (1000 rows)**
  ```bash
  kubectl run -it --rm psql-client --image=postgres:16 --restart=Never -n test-backups -- \
    psql -h postgres-test-postgresql.test-backups.svc.cluster.local -U testuser -d testdb
  ```

  ```sql
  CREATE TABLE test_data (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    created_at TIMESTAMP DEFAULT NOW()
  );

  INSERT INTO test_data (name)
  SELECT 'User ' || generate_series(1, 1000);

  SELECT COUNT(*) FROM test_data;  -- Expected: 1000
  \q
  ```

- [ ] **Wait for automatic backup**
  - Wait until 2:00 AM or manually trigger backup via Longhorn UI
  - Volume → Create Backup

- [ ] **Verify backup in MinIO**
  ```bash
  ssh alexanderp@pi-cm5-4 "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/"
  ```

- [ ] **Delete volume (destructive test)**
  ```bash
  kubectl scale statefulset postgres-test-postgresql -n test-backups --replicas=0
  kubectl delete pvc data-postgres-test-postgresql-0 -n test-backups
  ```

- [ ] **Restore volume from backup**
  - Longhorn UI → Backup tab → Find backup → Restore
  - Volume name: `postgres-data-restored`

- [ ] **Create PV for restored volume**
  - See [apps/postgres-test/README.md](apps/postgres-test/README.md) for PV/PVC YAML
  - Apply: `kubectl apply -f postgres-pv.yml && kubectl apply -f postgres-pvc.yml`

- [ ] **Scale up PostgreSQL**
  ```bash
  kubectl scale statefulset postgres-test-postgresql -n test-backups --replicas=1
  kubectl wait --for=condition=ready pod/postgres-test-postgresql-0 -n test-backups --timeout=120s
  ```

- [ ] **Verify data integrity**
  ```bash
  kubectl exec -it postgres-test-postgresql-0 -n test-backups -- \
    psql -U testuser -d testdb -c "SELECT COUNT(*) FROM test_data;"
  ```
  Expected: 1000 rows

**RTO**: 10-15 minutes for single volume restore
**RPO**: Last backup (max 24 hours with daily backups)

---

### Phase 4: Verify System Backups 📦

**What**: Confirm system backups capture all Longhorn configuration.

**When**: After Phase 3 succeeds.

**Tasks**:

- [ ] **Verify system backup job deployed** (from Phase 2)
  ```bash
  kubectl describe recurringjob weekly-system-backup -n longhorn-system
  ```
  Expected: `cron: 0 4 * * 0` (Sunday 4:00 AM), `task: system-backup`

- [ ] **Monitor first system backup**
  - **When**: After Sunday 4:00 AM
  - **Check**: Longhorn UI → System Backup tab
  - **Expected**: New system backup with label `recurring-job=weekly-system-backup`
  - **Verify MinIO**:
    ```bash
    ssh alexanderp@pi-cm5-4 "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/system-backups/"
    ```
  - Expected: `system-backup-<timestamp>.zip` (~1MB metadata file)

- [ ] **Verify all volumes have recent backups** (before cluster rebuild test)
  - Longhorn UI → Backup tab
  - All volumes should have backup < 24 hours old

---

### Phase 5: Full Cluster Rebuild Test (Optional) 🚨

**What**: Ultimate validation - complete cluster teardown and rebuild with data preservation.

**When**: After Phase 4 complete, during planned maintenance window.

**⚠️ WARNING**: This destroys the entire K3s cluster. Ensure all backups verified first.

**Pre-flight Checklist**:
- [ ] System Backup exists (Longhorn UI → System Backup tab)
- [ ] All volumes have recent backups (< 24 hours)
- [ ] MinIO accessible: `curl -I https://minio.jardoole.xyz:9000`
- [ ] All app configurations committed to git

**Procedure**:

```bash
# 1. Teardown cluster
make k3s-teardown

# 2. Rebuild cluster (includes Longhorn with backup target)
make k3s

# 3. Verify backup target persisted
# Longhorn UI → Settings → Backup Target (green checkmark)

# 4. Restore Longhorn System Backup (MANUAL UI STEP)
# Longhorn UI → System Backup tab → Find latest → Restore

# 5. Verify volumes restored
kubectl get volumes.longhorn.io -n longhorn-system
# Expected: All volumes in "Detached" state

# 6. Redeploy applications
make apps-deploy-all
# PVCs auto-bind to restored volumes

# 7. Verify data integrity
kubectl exec -it postgres-test-postgresql-0 -n test-backups -- \
  psql -U testuser -d testdb -c "SELECT COUNT(*) FROM test_data;"
# Expected: 1000 rows
```

**RTO**: 30-45 minutes (mostly hands-off)
**RPO**: Last backup (max 24 hours)

**Time Breakdown**:
- Teardown: 5 minutes
- Rebuild K3s: 15-20 minutes
- System Restore: 1-2 minutes (manual UI step)
- Redeploy apps: 5-10 minutes (auto PVC binding)
- Verification: 5-10 minutes
- **Total**: ~30-45 minutes

---

## Reference Links

### Official Longhorn Documentation
- **Backup Target Setup**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/backup-and-restore/set-backup-target/
- **System Backup**: https://longhorn.io/docs/1.10.0/advanced-resources/system-backup-restore/backup-longhorn-system
- **System Restore**: https://longhorn.io/docs/1.10.0/advanced-resources/system-backup-restore/restore-longhorn-system
- **Recurring Backups**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/scheduling-backups-and-snapshots/
- **Disaster Recovery**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/setup-disaster-recovery-volumes/

### Internal Documentation
- **[Longhorn Disaster Recovery Guide](docs/longhorn-disaster-recovery.md)** - Complete recovery procedures
- **[Longhorn App README](apps/longhorn/README.md)** - Backup configuration details
- **[PostgreSQL Test App](apps/postgres-test/README.md)** - Testing procedures

### Infrastructure
- **MinIO S3**: https://minio.jardoole.xyz:9000
- **Longhorn UI**: https://longhorn.jardoole.xyz
- **Backup Bucket**: `s3://longhorn-backups@eu-west-1/`
- **Credentials**: Service account in `group_vars/nas/vault.yml`

---

## Quick Commands

### Check Backup Status
```bash
# Recurring jobs
kubectl get recurringjobs.longhorn.io -n longhorn-system

# Recent backups
# Longhorn UI → Backup tab

# MinIO backups
ssh alexanderp@pi-cm5-4 "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/"

# System backups
ssh alexanderp@pi-cm5-4 "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/system-backups/"
```

### Deploy/Upgrade Longhorn
```bash
make app-upgrade APP=longhorn
```

### PostgreSQL Test Commands
```bash
# Deploy test app
make app-deploy APP=postgres-test

# Connect to database
kubectl run -it --rm psql-client --image=postgres:16 --restart=Never -n test-backups -- \
  psql -h postgres-test-postgresql.test-backups.svc.cluster.local -U testuser -d testdb

# Check row count
kubectl exec -it postgres-test-postgresql-0 -n test-backups -- \
  psql -U testuser -d testdb -c "SELECT COUNT(*) FROM test_data;"
```

---

## Future Work (Optional)

### Phase 6: Further Automation
- Automate System Backup restore (currently 1 manual UI click)
- Create verification playbook for automated data integrity checks
- Add pre-flight check playbook before cluster rebuild

### Offsite Replication
Implement 3-2-1 backup rule (3 copies, 2 media, 1 offsite):
- Current: 2 copies (Longhorn volumes + MinIO backups), 2 media (NVMe + SATA), 0 offsite
- Options: MinIO site replication, `mc mirror` cron, or rclone to cloud (Backblaze B2, AWS S3)
- Cost: ~$5-10/month for 500GB
- Reference: https://min.io/docs/minio/linux/operations/replication.html

---

## Key Takeaways

✅ **Automation Complete**: Backup target configured, recurring jobs defined, documentation created
✅ **Architecture Validated**: MinIO external to K3s (survives cluster failures)
✅ **Documentation Complete**: Disaster recovery guide with full procedures
⏳ **Awaiting Verification**: Automated backups, restore workflow, cluster rebuild

**Next Action**: Deploy recurring jobs and monitor first backup (Phase 2).
