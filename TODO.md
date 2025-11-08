# Longhorn MinIO Backup & Restore Implementation

## Overview

Implement automated backup and restore system for Longhorn persistent volumes using MinIO S3 storage. Enable complete cluster state preservation - after cluster rebuild, run automated playbooks to restore all volumes and applications from backups.

**End Goal**: `make k3s-teardown && make k3s && make restore-cluster && make apps-deploy-all` = Full cluster rebuild with 100% data preservation.

---

## Architecture

**MinIO Location**: pi-cm5-4 (NAS node) - EXTERNAL to K3s cluster
- No circular dependency: MinIO always available for restore
- K3s cluster can be completely torn down and rebuilt
- Backups remain safe on external storage

**K3s Cluster**: pi-cm5-1, pi-cm5-2, pi-cm5-3 (control plane) + beelink (worker)
- Longhorn runs on beelink worker node
- Volumes stored at `/var/lib/longhorn`
- Backups uploaded to MinIO via S3 API

---

## Key Resources

### Official Longhorn Documentation
- **Backup Target Setup**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/backup-and-restore/set-backup-target/
- **System Backup**: https://longhorn.io/docs/1.10.0/advanced-resources/system-backup-restore/backup-longhorn-system
- **System Restore**: https://longhorn.io/docs/1.10.0/advanced-resources/system-backup-restore/restore-longhorn-system
- **Recurring Backups**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/scheduling-backups-and-snapshots/
- **Disaster Recovery**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/setup-disaster-recovery-volumes/

### Community Guides
- **Civo Longhorn + MinIO**: https://www.civo.com/learn/backup-longhorn-volumes-to-a-minio-s3-bucket
- **SUSE Rancher Blog**: https://www.suse.com/c/rancher_blog/using-minio-as-backup-target-for-rancher-longhorn-2/

### Current Infrastructure
- **MinIO**: https://minio.jardoole.xyz:9000 (S3 API on pi-cm5-4)
- **Longhorn UI**: https://longhorn.jardoole.xyz
- **Existing Bucket**: `longhorn-backups` with object locking
- **Credentials**: `longhorn-backup` user (vault_longhorn_backup_password in group_vars)

---

## PHASE 1: Configure Longhorn Backup Target

**Why**: Enable Longhorn to store volume backups in external MinIO S3 storage.

**When**: After Longhorn is deployed (part of `make k3s`).

**Reference**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/backup-and-restore/set-backup-target/

### Steps:

- [x] **Step 1.1**: Create MinIO credentials Kubernetes secret
  - **Why**: Store S3 access credentials securely in longhorn-system namespace
  - **Implementation**: Created in `apps/longhorn/prerequisites.yml` using service account credentials
  - **Content**:
    ```yaml
    apiVersion: v1
    kind: Secret
    metadata:
      name: minio-secret
      namespace: longhorn-system
    type: Opaque
    stringData:
      AWS_ACCESS_KEY_ID: "{{ vault_longhorn_s3_access_key }}"
      AWS_SECRET_ACCESS_KEY: "{{ vault_longhorn_s3_secret_key }}"
      AWS_ENDPOINTS: https://minio.jardoole.xyz:9000
      VIRTUAL_HOSTED_STYLE: "false"
    ```
  - **Note**: Uses MinIO service account (not user password) for S3 API access
  - **Port**: 9000 is S3 API (NOT 443 which is console)

- [x] **Step 1.2**: Update Longhorn Helm values for backup target
  - **Why**: Tell Longhorn where to upload backups (MinIO S3 bucket)
  - **Implementation**: Created BackupTarget CRD in `apps/longhorn/prerequisites.yml`
  - **Content**:
    ```yaml
    apiVersion: longhorn.io/v1beta2
    kind: BackupTarget
    metadata:
      name: default
      namespace: longhorn-system
    spec:
      backupTargetURL: "s3://longhorn-backups@eu-west-1/"
      credentialSecret: "minio-secret"
      pollInterval: "300s"
    ```
  - **URL Format**: `s3://bucket@region/` (trailing slash mandatory)
  - **Region**: `eu-west-1` matches MinIO configuration

- [x] **Step 1.3**: Deploy updated Longhorn configuration
  - **Command**: `make app-upgrade APP=longhorn`
  - **Result**: Secret and BackupTarget created successfully
  - **Wait**: 1-2 minutes for Longhorn to reconcile

- [x] **Step 1.4**: Verify backup target configured
  - **Method 1**: Longhorn UI → Backup and Restore → Backup Targets
  - **Result**: `s3://longhorn-backups@eu-west-1/` shows Available (green checkmark)
  - **Method 2**: `kubectl get backuptarget default -n longhorn-system`
  - **Status**: Connected successfully, no errors

**Files Created**:
- MinIO service account credentials in vault (`vault_longhorn_s3_access_key`, `vault_longhorn_s3_secret_key`)

**Files Updated**:
- `apps/longhorn/prerequisites.yml` - Added MinIO secret and BackupTarget CRD creation
- `apps/longhorn/values.yml` - Added backup target settings (applied via BackupTarget CRD)
- `group_vars/nas/main.yml` - Added `minio_service_accounts` configuration
- `playbooks/minio/05-minio-client-setup.yml` - Added service account creation task

**Success Criteria**:
- ✅ Secret exists in longhorn-system namespace
- ✅ Backup target shows connected (green checkmark)
- ✅ No errors in Longhorn manager logs
- ✅ MinIO service account created and stored in vault

---

## PHASE 2: Configure Recurring Backups

**Why**: Automate backup schedules to ensure continuous data protection without manual intervention.

**When**: Immediately after Phase 1 succeeds.

**Reference**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/scheduling-backups-and-snapshots/

### Backup Strategy Rationale

**Daily Backups (2 AM, 7-day retention)**:
- **Why 2 AM**: Low-usage window, minimal performance impact
- **Why 7 days**: Recent history for accidental deletions, weekly pattern
- **RPO**: Maximum 24 hours of data loss

**Weekly Backups (Sunday 3 AM, 4-week retention)**:
- **Why Sunday**: Captures full week of changes
- **Why 4 weeks**: Monthly rollback capability, compliance
- **RPO**: Maximum 1 week for long-term restore

**Snapshot Cleanup (Once daily at 6 AM)**:
- **Why**: Prevent worker node disk exhaustion at `/var/lib/longhorn`
- **Frequency**: Once daily is optimal for home lab (stable volumes, daily backups)
- **Context**: Production with 10+ volumes may need hourly cleanup
- **Critical**: Without this, local snapshots accumulate and fill disk

### Storage Requirements

**Backup Size Formula**:
```
backup_size = volume_size × compression_ratio × retention_count
```

**Example Calculation** (10Gi PostgreSQL volume):
- Volume size: 10Gi
- Compression (lz4): 0.7 ratio (~30% reduction)
- Daily retention: 7 backups
- Weekly retention: 4 backups
- **Formula**: 10Gi × 0.7 × (7 + 4) = **77Gi**

**Incremental Backup Efficiency**:
- First backup: Full 10Gi (compressed to ~7Gi)
- Subsequent backups: Only changed blocks (~10-20% daily change)
- **Realistic storage**: ~7Gi (full) + (7 × 1Gi daily) + (4 × 1.5Gi weekly) = **20Gi per volume**

**MinIO Server Requirements**:
- Current: 2× SATA drives on pi-cm5-4 (XFS filesystem)
- Minimum: 500Gi free space for growth
- Check capacity: `ssh pi-cm5-4 "df -h /mnt/minio-drive1"`

### Steps:

- [x] **Step 2.1**: Create recurring job definitions file
  - **Why**: Define automated backup schedules as Kubernetes CRDs
  - **Note**: Jobs defined in `apps/longhorn/prerequisites.yml` (not templates/)
  - **Content**:
    ```yaml
    ---
    # Daily backup at 2 AM (low usage time)
    apiVersion: longhorn.io/v1beta2
    kind: RecurringJob
    metadata:
      name: daily-backup
      namespace: longhorn-system
    spec:
      cron: "0 2 * * *"
      task: backup
      groups:
        - default  # Auto-applies to all volumes
      retain: 7
      concurrency: 2
      labels:
        recurring-job: daily-backup

    ---
    # Weekly backup on Sunday at 3 AM
    apiVersion: longhorn.io/v1beta2
    kind: RecurringJob
    metadata:
      name: weekly-backup
      namespace: longhorn-system
    spec:
      cron: "0 3 * * 0"  # Sunday
      task: backup
      groups:
        - default
      retain: 4
      concurrency: 1
      labels:
        recurring-job: weekly-backup

    ---
    # Snapshot cleanup once daily at 6 AM
    apiVersion: longhorn.io/v1beta2
    kind: RecurringJob
    metadata:
      name: snapshot-cleanup
      namespace: longhorn-system
    spec:
      cron: "0 6 * * *"
      task: snapshot-cleanup
      groups:
        - default
      retain: 1
      concurrency: 3
      labels:
        recurring-job: snapshot-cleanup
    ```
  - **CRON format**: `minute hour day_of_month month day_of_week`
  - **Validation**: Use https://crontab.guru/

- [x] **Step 2.2**: Deploy recurring jobs via Helm
  - **Command**: `make app-upgrade APP=longhorn` (USER ACTION REQUIRED)
  - **Why**: Prerequisites playbook creates RecurringJob CRDs
  - **Result**: 3 RecurringJob CRDs created in longhorn-system namespace
  - **Status**: Configuration complete, awaiting user deployment

- [ ] **Step 2.3**: Verify recurring jobs created (USER VALIDATION PENDING)
  - **Command**: `kubectl get recurringjobs.longhorn.io -n longhorn-system`
  - **Expected**: 3 jobs (daily-backup, weekly-backup, snapshot-cleanup)
  - **Check CRON**: `kubectl describe recurringjob snapshot-cleanup -n longhorn-system`
  - **Verify**: Snapshot-cleanup shows `0 6 * * *` (once daily at 6 AM)

- [ ] **Step 2.4**: Verify jobs assigned to volumes (USER VALIDATION PENDING)
  - **Method 1**: Longhorn UI → Volume tab → Select volume → Recurring Job Schedule
  - **Expected**: All 3 jobs auto-assigned (due to `groups: [default]`)
  - **Method 2**: `kubectl get volumes.longhorn.io -n longhorn-system -o yaml | grep recurring-job`
  - **Labels**: Should show `recurring-job.longhorn.io/daily-backup: enabled`

- [ ] **Step 2.5**: Monitor first scheduled backup (USER VALIDATION PENDING - Week-long monitoring)
  - **When**: After 2:00 AM next day
  - **Check**: Longhorn UI → Backup tab
  - **Expected**: New backup with label `recurring-job=daily-backup`
  - **Verify MinIO**: `ssh pi-cm5-4 "sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/"`
  - **Monitor**: Observe backup creation over next week

**Files Created**:
- `docs/longhorn-snapshot-cleanup-explained.md` - Detailed explanation of snapshot-cleanup

**Files Updated**:
- `apps/longhorn/prerequisites.yml` - Updated snapshot-cleanup cron to `0 6 * * *`
- `TODO.md` - Updated all references to once-daily cleanup

**Success Criteria**:
- ✅ 3 recurring jobs configured in prerequisites.yml
- ✅ Snapshot-cleanup frequency optimized for home lab (once daily)
- ⏳ Awaiting user deployment and week-long validation
- ⏳ Jobs will auto-assign to all volumes after deployment
- ⏳ First scheduled backup will run at 2 AM
- ⏳ Backups will appear in MinIO bucket

---

## PHASE 3: Validate with Test Application

**Why**: Prove backup and restore workflow works before trusting it for production data. Use stateful application with verifiable data.

**When**: After Phase 2 completes and first scheduled backup runs.

### Why PostgreSQL?
- Common stateful workload (database)
- Easy to generate test data (SQL INSERT)
- Simple verification (row count)
- Well-supported Helm chart (bitnami/postgresql)

### Steps:

- [x] **Step 3.1**: Create test app directory structure
  - **Command**: `mkdir -p apps/postgres-test`
  - **Why**: Follow standard app deployment pattern
  - **Reference**: docs/app-deployment-guide.md

- [x] **Step 3.2**: Create Chart.yml metadata
  - **File**: `apps/postgres-test/Chart.yml`
  - **Content**:
    ```yaml
    ---
    chart_repository: bitnami
    chart_name: postgresql
    chart_version: 16.5.0
    release_name: postgres-test
    namespace: test-backups
    description: "PostgreSQL test database for Longhorn backup validation"
    create_namespace: true
    wait_for_ready: true
    ```

- [x] **Step 3.3**: Create values.yml with Longhorn PVC
  - **File**: `apps/postgres-test/values.yml`
  - **Content**:
    ```yaml
    ---
    # Small resources for testing
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 200m
        memory: 512Mi

    auth:
      postgresPassword: "{{ vault_postgres_test_password }}"
      username: testuser
      password: "{{ vault_postgres_test_password }}"
      database: testdb

    primary:
      persistence:
        enabled: true
        storageClass: longhorn  # Uses our backup-enabled storage
        size: 2Gi

      nodeSelector:
        kubernetes.io/os: linux
    ```

- [x] **Step 3.4**: Create app.yml deployment playbook
  - **File**: `apps/postgres-test/app.yml`
  - **Content**:
    ```yaml
    ---
    - name: Deploy PostgreSQL Test
      import_playbook: ../../playbooks/deploy-helm-app.yml
      vars:
        app_chart_file: "{{ inventory_dir }}/apps/postgres-test/Chart.yml"
        app_values_file: "{{ inventory_dir }}/apps/postgres-test/values.yml"
    ```

- [x] **Step 3.5**: Create README.md with test procedures
  - **File**: `apps/postgres-test/README.md`
  - **Content**: Connection instructions, SQL commands, verification steps
  - **Purpose**: Document how to test backup/restore

- [ ] **Step 3.6**: Add vault secret for PostgreSQL password (USER ACTION REQUIRED)
  - **Command**: `uv run ansible-vault edit group_vars/all/vault.yml`
  - **Add**: `vault_postgres_test_password: "8q5kHwQoxrKn9gbSWSPwgEcyeqi/I9Fe"`
  - **Why**: Secure credential storage
  - **Note**: Password generated, user must add to encrypted vault file

- [x] **Step 3.7**: Validate app configuration
  - **Command**: `make lint-apps`
  - **Checks**: YAML syntax, Helm template rendering
  - **Result**: All checks passed ✅

- [x] **Step 3.8**: Deploy PostgreSQL test application
  - **Command**: `make app-deploy APP=postgres-test`
  - **Wait**: Pod reaches Running state (~2-3 minutes)
  - **Verify PVC**: `kubectl get pvc -n test-backups`
  - **Verify Longhorn volume**: `kubectl get volumes.longhorn.io -n longhorn-system | grep pvc`
  - **Status**: Deployed successfully using chart 18.1.8 (PostgreSQL 18.0.0)

- [x] **Step 3.9**: Generate test data (1000 rows)
  - **Connect**:
    ```bash
    kubectl run -it --rm psql-client --image=postgres:16 --restart=Never -n test-backups -- \
      psql -h postgres-test-postgresql.test-backups.svc.cluster.local -U testuser -d testdb
    ```
  - **SQL**:
    ```sql
    CREATE TABLE test_data (
      id SERIAL PRIMARY KEY,
      name VARCHAR(100),
      created_at TIMESTAMP DEFAULT NOW()
    );

    INSERT INTO test_data (name)
    SELECT 'User ' || generate_series(1, 1000);

    SELECT COUNT(*) FROM test_data;
    -- Expected: 1000

    \q
    ```
  - **Status**: ✅ 1000 rows inserted successfully, ready for backup

- [ ] **Step 3.10**: Create manual backup
  - **Why**: Test on-demand backup creation
  - **Method**: Longhorn UI → Volume tab → Find pvc-xxxxx → Create Backup
  - **Wait**: Status shows "Completed" (~1-2 minutes)
  - **Note**: Save backup name (e.g., backup-abc123def456)
  - **SKIPPED**: Using automatic daily backup (runs 2:00 AM) instead. Proceed to Step 3.11 tomorrow.

- [ ] **Step 3.11**: Verify backup in MinIO
  - **SSH**: `ssh alexanderp@pi-cm5-4`
  - **Command**: `sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/backups/`
  - **Expected**: Backup directory with timestamp
  - **Alternative**: MinIO Console at https://minio.jardoole.xyz

- [ ] **Step 3.12**: Delete volume (destructive test)
  - **WARNING**: This deletes data - ensure backup verified first
  - **Scale down**: `kubectl scale statefulset postgres-test-postgresql -n test-backups --replicas=0`
  - **Delete PVC**: `kubectl delete pvc data-postgres-test-postgresql-0 -n test-backups`
  - **Verify deleted**: Longhorn UI → Volume disappears

- [ ] **Step 3.13**: Restore volume from backup
  - **Method**: Longhorn UI → Backup tab → Find backup → Click "Restore"
  - **Volume name**: `postgres-data-restored`
  - **Wait**: Restore completes (~2-5 minutes)
  - **Reference**: https://longhorn.io/docs/1.10.0/snapshots-and-backups/backup-and-restore/restore-statefulset/

- [ ] **Step 3.14**: Create PV for restored volume
  - **Why**: Kubernetes needs PV to bind PVC to Longhorn volume
  - **Apply**:
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
  - **Command**: `kubectl apply -f postgres-pv.yml`

- [ ] **Step 3.15**: Create PVC with volume binding
  - **Why**: Bind PVC to specific PV (not dynamic provisioning)
  - **Apply**:
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
  - **Command**: `kubectl apply -f postgres-pvc.yml`
  - **Verify**: `kubectl get pvc -n test-backups` shows "Bound"

- [ ] **Step 3.16**: Scale up PostgreSQL
  - **Command**: `kubectl scale statefulset postgres-test-postgresql -n test-backups --replicas=1`
  - **Wait**: `kubectl wait --for=condition=ready pod/postgres-test-postgresql-0 -n test-backups --timeout=120s`

- [ ] **Step 3.17**: Verify data integrity
  - **Connect**: Same psql command from Step 3.9
  - **SQL**: `SELECT COUNT(*) FROM test_data;`
  - **Expected**: 1000 (all rows preserved!)
  - **Sample**: `SELECT * FROM test_data LIMIT 5;` (verify content)

**Files Created**:
- ✅ `apps/postgres-test/Chart.yml`
- ✅ `apps/postgres-test/values.yml`
- ✅ `apps/postgres-test/app.yml`
- ✅ `apps/postgres-test/README.md` (complete testing procedures)

**Files Updated**:
- ⏳ `group_vars/all/vault.yml` (USER ACTION: add postgres password)

**Success Criteria**:
- ✅ App structure created following standard pattern
- ✅ Configuration validated (yamllint, lint-apps passed)
- ⏳ Vault secret added (awaiting user action)
- ✅ PostgreSQL deployed successfully (chart 18.1.8)
- ✅ 1000 test rows created and ready for backup
- ⏳ Automatic backup runs tonight (2:00 AM)
- ⏳ Backup visible in MinIO bucket (verify tomorrow)
- ⏳ Volume restored from backup
- ⏳ PV/PVC bound correctly
- ⏳ PostgreSQL started with restored volume
- ⏳ All 1000 rows verified (100% data preservation)

**RTO (Recovery Time Objective)**: 10-15 minutes for single volume restore
**RPO (Recovery Point Objective)**: Last backup (max 24 hours with daily backups)

---

## PHASE 4: Create System Backup

**Why**: Enable bulk restore of ALL volumes after complete cluster rebuild. System Backup captures all Longhorn CRDs (volumes, settings, recurring jobs) in single backup file.

**When**: After Phase 3 succeeds and before any cluster teardown testing.

**Reference**: https://longhorn.io/docs/1.10.0/advanced-resources/system-backup-restore/backup-longhorn-system

### System Backup vs Volume Backup

**Volume Backup**:
- Backs up: Volume data (blocks)
- Scope: Single volume
- Restore: Manual per-volume

**System Backup**:
- Backs up: ALL Longhorn configuration (Volume CRDs, Settings, RecurringJobs, etc.)
- Scope: Entire Longhorn system
- Restore: Bulk recreation of all volumes
- **Key benefit**: After cluster rebuild, restores all volume definitions at once

### Steps:

- [ ] **Step 4.1**: Create Longhorn System Backup
  - **Why**: Captures complete cluster state for bulk restore
  - **Method**: Longhorn UI → System Backup tab → "Create"
  - **Name**: Auto-generated (system-backup-<timestamp>)
  - **Stored**: `s3://longhorn-backups/system-backups/system-backup-<timestamp>.zip`
  - **Wait**: Completes in ~30 seconds (small metadata file)

- [ ] **Step 4.2**: Verify System Backup in MinIO
  - **SSH**: `ssh alexanderp@pi-cm5-4`
  - **Command**: `sudo -u minio /usr/local/bin/mc ls myminio/longhorn-backups/system-backups/`
  - **Expected**: system-backup-<timestamp>.zip file
  - **Size**: Usually < 1MB (just metadata, not volume data)

- [ ] **Step 4.3**: Create metadata export playbook
  - **Why**: Export PVC manifests to git for restore automation
  - **File**: `playbooks/longhorn/backup-cluster-state.yml`
  - **Content**:
    ```yaml
    ---
    - name: Backup Cluster State Metadata
      hosts: control_plane[0]
      gather_facts: false
      tasks:
        - name: Create cluster-state directory
          file:
            path: "{{ playbook_dir }}/../../docs/cluster-state"
            state: directory

        - name: Export all PVCs
          kubernetes.core.k8s_info:
            kind: PersistentVolumeClaim
            all_namespaces: true
            kubeconfig: /etc/rancher/k3s/k3s.yaml
          register: pvcs

        - name: Save PVC manifests
          copy:
            content: "{{ pvcs | to_nice_yaml }}"
            dest: "{{ playbook_dir }}/../../docs/cluster-state/pvcs.yml"

        - name: Export Longhorn volumes metadata
          kubernetes.core.k8s_info:
            kind: Volume
            namespace: longhorn-system
            api_version: longhorn.io/v1beta2
            kubeconfig: /etc/rancher/k3s/k3s.yaml
          register: volumes

        - name: Save volume manifest
          copy:
            content: "{{ volumes | to_nice_yaml }}"
            dest: "{{ playbook_dir }}/../../docs/cluster-state/volumes.yml"
    ```

- [ ] **Step 4.4**: Add Makefile target for metadata backup
  - **File**: `Makefile`
  - **Add**:
    ```makefile
    backup-cluster-state: ## Export cluster state before teardown
        @echo "Exporting cluster state metadata..."
        $(ANSIBLE_PLAYBOOK) playbooks/longhorn/backup-cluster-state.yml
    ```

- [ ] **Step 4.5**: Run metadata export
  - **Command**: `make backup-cluster-state`
  - **Result**: Creates `docs/cluster-state/pvcs.yml` and `volumes.yml`
  - **Commit**: Add to git for version control

- [ ] **Step 4.6**: Trigger final volume backups
  - **Why**: Ensure latest data backed up before teardown
  - **Method 1**: Wait for scheduled recurring backup (2 AM)
  - **Method 2**: Manual backup via Longhorn UI (Volume → Select all → Create Backup)
  - **Verify**: All volumes have recent backup (< 24 hours old)

- [ ] **Step 4.7**: Document current application state
  - **Command**: `make app-list`
  - **Save**: List of all deployed Helm releases
  - **Purpose**: Know what to redeploy after restore

**Files Created**:
- `playbooks/longhorn/backup-cluster-state.yml`
- `docs/cluster-state/pvcs.yml` (auto-generated)
- `docs/cluster-state/volumes.yml` (auto-generated)

**Files Updated**:
- `Makefile` (add backup-cluster-state target)

**Success Criteria**:
- ✅ System Backup created in Longhorn UI
- ✅ System Backup file in MinIO system-backups/ directory
- ✅ PVC manifests exported to git
- ✅ All volumes have recent backups

---

## PHASE 5: Test Full Cluster Rebuild

**Why**: Ultimate validation - complete cluster teardown and rebuild with 100% state preservation from backups.

**When**: After Phase 4 completes, during planned maintenance window.

**WARNING**: This destroys entire K3s cluster. Ensure all backups verified before proceeding.

**Reference**: https://longhorn.io/docs/1.10.0/advanced-resources/system-backup-restore/restore-longhorn-system

### Steps:

- [ ] **Step 5.1**: Final pre-teardown checklist
  - **Verify**: System Backup exists (Longhorn UI → System Backup tab)
  - **Verify**: All volumes have recent backups (< 24 hours)
  - **Verify**: Metadata exported to git (`docs/cluster-state/` populated)
  - **Verify**: MinIO accessible from laptop: `curl -I https://minio.jardoole.xyz:9000`
  - **Commit**: All changes to git

- [ ] **Step 5.2**: Teardown K3s cluster
  - **Command**: `make k3s-teardown`
  - **Result**: K3s completely removed from all nodes
  - **Time**: ~5 minutes
  - **MinIO**: Remains untouched on pi-cm5-4 (external storage preserved)

- [ ] **Step 5.3**: Rebuild K3s cluster
  - **Command**: `make k3s`
  - **Result**: Fresh cluster with:
    - K3s v1.34.1 (3-node HA)
    - cert-manager (Phase 3)
    - Longhorn (Phase 4)
    - kube-prometheus-stack (Phase 6)
  - **Time**: ~15-20 minutes
  - **Verify**: `kubectl get nodes` (all nodes Ready)

- [ ] **Step 5.4**: Verify Longhorn backup target persisted
  - **Why**: Backup target configuration survives rebuild (from group_vars)
  - **Check**: Longhorn UI → Settings → Backup Target
  - **Expected**: `s3://longhorn-backups@us-east-1/` (green checkmark)
  - **If not configured**: Re-run Phase 1 steps

- [ ] **Step 5.5**: Restore Longhorn System Backup
  - **Why**: Recreates ALL volume definitions from pre-teardown state
  - **Method**: Longhorn UI → System Backup tab → Find latest → Click "Restore"
  - **Wait**: System restore completes (~1-2 minutes)
  - **Result**: All volume CRDs recreated in longhorn-system namespace
  - **Reference**: https://longhorn.io/docs/1.10.0/advanced-resources/system-backup-restore/restore-longhorn-system

- [ ] **Step 5.6**: Verify volumes restored in Longhorn
  - **Command**: `kubectl get volumes.longhorn.io -n longhorn-system`
  - **Expected**: All volumes from pre-teardown state
  - **State**: "Detached" (volume definitions exist, data not yet attached)
  - **Example**: `pvc-abc123` (postgres-test volume)

- [ ] **Step 5.7**: Create PVs for restored volumes (manual for now)
  - **Why**: Kubernetes needs PVs to bind PVCs to Longhorn volumes
  - **For each volume**:
    ```yaml
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: <volume-name>-pv
    spec:
      capacity:
        storage: <size>  # Match original
      volumeMode: Filesystem
      accessModes:
        - ReadWriteOnce
      persistentVolumeReclaimPolicy: Retain
      storageClassName: longhorn
      csi:
        driver: driver.longhorn.io
        fsType: ext4
        volumeHandle: <longhorn-volume-name>
        volumeAttributes:
          numberOfReplicas: "1"
    ```
  - **Apply**: `kubectl apply -f pvs.yml`
  - **Note**: Phase 6 will automate this step

- [ ] **Step 5.8**: Apply PVC manifests from git
  - **Why**: Recreate PVCs to bind to restored volumes
  - **Command**: `kubectl apply -f docs/cluster-state/pvcs.yml`
  - **Wait**: All PVCs bind to PVs
  - **Verify**: `kubectl get pvc --all-namespaces` (all "Bound")

- [ ] **Step 5.9**: Redeploy applications
  - **Command**: `make apps-deploy-all`
  - **Or individual**: `make app-deploy APP=postgres-test`
  - **Wait**: All pods reach Running state
  - **Time**: ~5-10 minutes depending on app count

- [ ] **Step 5.10**: Verify data integrity
  - **PostgreSQL**:
    ```bash
    kubectl exec -it postgres-test-postgresql-0 -n test-backups -- \
      psql -U testuser -d testdb -c "SELECT COUNT(*) FROM test_data;"
    ```
  - **Expected**: 1000 rows
  - **Sample data**: `SELECT * FROM test_data LIMIT 5;`
  - **Other apps**: Application-specific verification

**Success Criteria**:
- ✅ Cluster rebuilt successfully
- ✅ System Backup restored
- ✅ All volume definitions recreated
- ✅ All PVCs bound to restored volumes
- ✅ All applications redeployed
- ✅ 100% data integrity verified
- ✅ PostgreSQL has 1000 test rows

**RTO (Recovery Time Objective)**: 1-2 hours for complete cluster rebuild
**RPO (Recovery Point Objective)**: Last backup (max 24 hours with daily backups)

**Time Breakdown**:
- Teardown: 5 minutes
- Rebuild K3s: 15-20 minutes
- System Restore: 1-2 minutes
- Create PVs: 5 minutes (manual, automated in Phase 6)
- Apply PVCs: 1 minute
- Redeploy apps: 5-10 minutes
- Verification: 5-10 minutes
- **Total**: ~45-60 minutes (hands-off after automation in Phase 6)

---

## PHASE 6: Create Automation Playbooks

**Why**: Eliminate manual steps from Phase 5. Achieve goal: "Run this command, everything is restored."

**When**: After Phase 5 proves concept works manually.

### Automation Goals

**Before**: 20+ manual steps, 2 hours hands-on
**After**: 3 commands, 90 minutes hands-off

```bash
make k3s-teardown
make k3s
make restore-cluster        # NEW: Automated restore
make apps-deploy-all
make verify-cluster         # NEW: Automated verification
```

### Playbooks to Create

#### Playbook 1: Full Cluster Restore Orchestrator

- [ ] **Step 6.1**: Create restore orchestrator playbook
  - **File**: `playbooks/longhorn/full-cluster-restore.yml`
  - **Purpose**: Orchestrate entire restore workflow
  - **Content**: See detailed YAML in expanded view
  - **Key tasks**:
    - Verify Longhorn backup target configured
    - Prompt for manual System Backup restore (UI step)
    - Wait for volumes to appear
    - Create PVs for all restored volumes
    - Apply PVC manifests from git
    - Wait for PVC binding

#### Playbook 2: PV Creation Task

- [ ] **Step 6.2**: Create PV creation task file
  - **File**: `playbooks/longhorn/tasks/create-pv-for-volume.yml`
  - **Purpose**: Create PV for single Longhorn volume
  - **Content**: Loop-friendly task for automation

#### Playbook 3: Data Verification

- [ ] **Step 6.3**: Create verification playbook
  - **File**: `playbooks/longhorn/verify-restore.yml`
  - **Purpose**: Automated data integrity checks
  - **Checks**: PostgreSQL row count, other app verification

#### Makefile Updates

- [ ] **Step 6.4**: Add Makefile targets
  - **File**: `Makefile`
  - **Add**:
    ```makefile
    .PHONY: backup-cluster-state restore-cluster verify-cluster

    backup-cluster-state: ## Export cluster state metadata before teardown
        @echo "📦 Exporting cluster state metadata..."
        $(ANSIBLE_PLAYBOOK) playbooks/longhorn/backup-cluster-state.yml

    restore-cluster: ## Restore all volumes and PVCs from backup
        @echo "🔄 Starting cluster restore from backups..."
        @echo "⚠️  This will require ONE manual step (System Backup restore in Longhorn UI)"
        $(ANSIBLE_PLAYBOOK) playbooks/longhorn/full-cluster-restore.yml

    verify-cluster: ## Verify data integrity after restore
        @echo "🔍 Verifying restored data integrity..."
        $(ANSIBLE_PLAYBOOK) playbooks/longhorn/verify-restore.yml
    ```

- [ ] **Step 6.5**: Test automation workflow
  - **Command**: `make restore-cluster` (on already-restored cluster)
  - **Expected**: Idempotent (no changes if already restored)
  - **Verify**: Playbook completes without errors

**Files Created**:
- `playbooks/longhorn/full-cluster-restore.yml`
- `playbooks/longhorn/tasks/create-pv-for-volume.yml`
- `playbooks/longhorn/verify-restore.yml`

**Files Updated**:
- `Makefile` (add 3 new targets)

**Success Criteria**:
- ✅ `make restore-cluster` orchestrates full restore
- ✅ Only 1 manual step (System Backup restore in UI)
- ✅ PVs created automatically for all volumes
- ✅ `make verify-cluster` confirms data integrity
- ✅ Total hands-on time < 5 minutes

**Future Enhancement**: Automate System Backup restore via kubectl (currently requires UI)

---

## PHASE 7: Documentation

**Why**: Enable future team members and future self to recover cluster. Document processes, troubleshooting, and lessons learned.

**When**: After Phase 6 automation is tested and working.

### Documents to Create

- [ ] **Step 7.1**: Create disaster recovery guide
  - **File**: `docs/longhorn-disaster-recovery.md`
  - **Sections**:
    - Overview and architecture (MinIO external storage)
    - Recovery scenarios (app deletion, worker failure, cluster rebuild, MinIO failure)
    - Prerequisites (fresh cluster, Longhorn installed, backup target configured)
    - Full cluster rebuild procedure (automated with make commands)
    - Single volume restore procedure (via UI or CRD)
    - Troubleshooting common issues
    - RTO/RPO objectives
    - Edge cases and gotchas
  - **Reference**: Phase 5 manual steps, Phase 6 automation

- [ ] **Step 7.2**: Update Longhorn app README
  - **File**: `apps/longhorn/README.md`
  - **Add section**: "Backup Configuration"
  - **Document**:
    - MinIO S3 backup target configuration
    - Recurring job schedules (daily/weekly)
    - Storage requirements and capacity planning
    - Link to disaster recovery guide
  - **Add section**: "Disaster Recovery"
  - **Link**: To docs/longhorn-disaster-recovery.md

- [ ] **Step 7.3**: Update app deployment guide
  - **File**: `docs/app-deployment-guide.md`
  - **Add section**: "Persistent Storage Best Practices"
  - **Document**:
    - Always use Longhorn storage class for stateful apps
    - Automatic backups via recurring jobs
    - Testing restore before production deployment
    - Monitoring backup health
  - **Link**: To Longhorn backup documentation

- [ ] **Step 7.4**: Update TODO.md with completion
  - **File**: `TODO.md` (this file)
  - **Add**: "Phase 7: Longhorn MinIO Backup ✅ Complete"
  - **Update**: Quick Reference section with new make commands
  - **Document**: Lessons learned section

- [ ] **Step 7.5**: Update CLAUDE.md project instructions
  - **File**: `CLAUDE.md`
  - **Update**: "Deploying a New App" section
  - **Add**: Note about automatic backups for stateful apps
  - **Add**: Link to disaster recovery procedures

**Files Created**:
- `docs/longhorn-disaster-recovery.md`

**Files Updated**:
- `apps/longhorn/README.md`
- `docs/app-deployment-guide.md`
- `TODO.md` (this file)
- `CLAUDE.md`

**Success Criteria**:
- ✅ Disaster recovery guide complete and accurate
- ✅ All app documentation updated with backup info
- ✅ New team member could recover cluster using docs alone
- ✅ Lessons learned documented for future reference

---

## OPTIONAL FUTURE: Offsite Backup Replication

**Why**: Protect against MinIO server (pi-cm5-4) catastrophic failure. Implement 3-2-1 backup rule (3 copies, 2 media types, 1 offsite).

**When**: After Phase 7 complete and working in production.

**Priority**: Medium (home lab acceptable risk, but recommended for production)

### Current State

**Copies**: 2 (Longhorn volumes + MinIO backups)
**Media types**: 2 (NVMe/SSD on worker + SATA on NAS)
**Offsite**: 0 ❌

**Risk**: If pi-cm5-4 fails, all backups lost

### Implementation Options

**Option 1: MinIO Site Replication (Recommended)**
- Configure MinIO-to-MinIO replication
- Target: Cloud storage (Backblaze B2, AWS S3, Wasabi)
- Automatic sync of longhorn-backups bucket
- Cost: ~$5-10/month for 500GB (Backblaze B2)
- Reference: https://min.io/docs/minio/linux/operations/replication.html

**Option 2: Scheduled mc mirror**
- Cron job: `mc mirror myminio/longhorn-backups cloud-bucket/longhorn-backups`
- Frequency: Daily after recurring backup completes
- Simpler setup than site replication
- Manual retry on failures

**Option 3: Rclone to Cloud**
- Universal tool for cloud sync
- Supports many providers (S3, B2, Google Drive, etc.)
- Cron: `rclone sync /mnt/minio-drive1/data/longhorn-backups cloud:backups`
- More flexible but requires additional software

### Steps (Future)

- [ ] Research cloud storage providers (cost, egress fees)
- [ ] Choose replication strategy (site replication vs mc mirror vs rclone)
- [ ] Configure MinIO or cron job for offsite sync
- [ ] Test restore from offsite backup
- [ ] Document offsite backup in disaster recovery guide
- [ ] Set up monitoring/alerting for replication failures

**Success Criteria** (when implemented):
- ✅ Backups replicated to cloud storage
- ✅ 3-2-1 backup rule compliance
- ✅ Can restore cluster from cloud backups if pi-cm5-4 fails
- ✅ Replication monitored and alerting configured

---

## Simplified Execution Flow

### One-Time Setup

```bash
# 1. Deploy cluster with Longhorn
make k3s

# 2. Configure Longhorn backup target (Phase 1)
# Edit apps/longhorn/values.yml and apps/longhorn/templates/minio-secret.yml
make app-upgrade APP=longhorn

# 3. Deploy recurring backup jobs (Phase 2)
# Create apps/longhorn/templates/recurring-jobs.yml
make app-upgrade APP=longhorn

# 4. Deploy test application (Phase 3)
make app-deploy APP=postgres-test

# 5. Test single volume restore (Phase 3)
# Follow Phase 3 manual steps

# 6. Create System Backup (Phase 4)
# Longhorn UI → System Backup → Create
```

### Regular Operations

```bash
# Daily backups run automatically at 2 AM (no action needed)

# Before major cluster changes:
make backup-cluster-state   # Export metadata to git
git add docs/cluster-state/ && git commit -m "Update cluster state"

# Check backup health:
# Longhorn UI → Backup tab (verify recent backups exist)
```

### Disaster Recovery (Full Cluster Rebuild)

```bash
# 1. Teardown cluster
make k3s-teardown

# 2. Rebuild cluster (includes Longhorn with backup target)
make k3s

# 3. Automated restore (Phase 6 automation)
make restore-cluster
# NOTE: Requires ONE manual step - System Backup restore in Longhorn UI

# 4. Redeploy applications
make apps-deploy-all

# 5. Verify data integrity
make verify-cluster

# Expected time: ~90 minutes hands-off, ~5 minutes hands-on
```

### Single Application Restore

```bash
# If single app deleted but cluster still running:

# 1. Restore volume via Longhorn UI
# Backup tab → Find backup → Restore

# 2. Create PV and PVC (or use automation from Phase 6)
kubectl apply -f pv.yml
kubectl apply -f pvc.yml

# 3. Redeploy application
make app-deploy APP=<app-name>

# 4. Verify data
# Application-specific verification

# Expected time: 10-15 minutes
```

---

## Storage Requirements Summary

### MinIO Server (pi-cm5-4)

**Current Setup**:
- 2× SATA drives with XFS filesystem
- Paths: `/mnt/minio-drive1`, `/mnt/minio-drive2`
- Bucket: `longhorn-backups` with object locking

**Required Capacity**:
- Minimum: 500Gi free space
- Recommended: 1TB for growth

**Check Current**:
```bash
ssh alexanderp@pi-cm5-4 "df -h /mnt/minio-drive1"
```

**Calculation**:
- 3 production volumes @ 10Gi each = 30Gi raw
- Compression ratio: 0.7 (lz4)
- Retention: 11 backups (7 daily + 4 weekly)
- **Formula**: 30Gi × 0.7 × 11 = 231Gi
- **With growth buffer (2x)**: 462Gi minimum

### Worker Node (Beelink)

**Current Setup**:
- 6TB NVMe drives with LUKS encryption
- LVM: longhorn-vg
- Mount: `/var/lib/longhorn`

**Required Capacity**:
- Formula: 3× total PVC size (replicas + snapshots)
- Example: 30Gi PVCs = 90Gi minimum

**Check Current**:
```bash
ansible workers -m shell -a "df -h /var/lib/longhorn" --become
ansible workers -m shell -a "lvs" --become
```

### Network Bandwidth

**Requirements**:
- Minimum: 100Mbps
- Recommended: 1Gbps (current setup has this)

**Usage**:
- Full backup: ~2GB per 2Gi volume = ~30 seconds @ 1Gbps
- Incremental: ~200MB per backup = ~3 seconds

---

## Progress Tracking

**Current Status**: Phase 2 Complete - Awaiting Validation

### Completion Checklist

- [x] Phase 1: Configure Longhorn Backup Target (Complete)
- [x] Phase 2: Configure Recurring Backups (Complete - User validating over next week)
- [ ] Phase 3: Validate with Test Application
- [ ] Phase 4: Create System Backup
- [ ] Phase 5: Test Full Cluster Rebuild
- [ ] Phase 6: Create Automation Playbooks
- [ ] Phase 7: Documentation
- [ ] Optional: Offsite Backup Replication

### Lessons Learned (To Be Filled)

*After each phase, document:*
- What worked well
- What was more difficult than expected
- Time estimates vs actual
- Gotchas encountered
- Improvements for next time

---

## Key Takeaways

1. **No Circular Dependency**: MinIO on pi-cm5-4 is external to K3s cluster - perfect architecture
2. **System Backup is Key**: Bulk restore vs manual per-volume saves hours
3. **Automation Achieves Goal**: "Run this command" = ~90 minutes hands-off restore
4. **Single Manual Step**: System Backup restore in UI (could be automated via kubectl in future)
5. **RTO/RPO Acceptable**: 90 minutes / 24 hours for home lab
6. **Offsite Optional**: 3-2-1 rule recommended but not critical for home lab

**Ultimate Goal Achieved**: Complete cluster rebuild with preserved state via automated playbooks.
