# Home Lab Infrastructure TODO

## Overview

This document outlines the step-by-step plan to build a complete home lab infrastructure with K3s cluster, Longhorn distributed storage, and MinIO backup service.

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ K3s Cluster                                                     │
│ ├── Control Plane (pi-cm5-1)                                   │
│ ├── Workers (pi-cm5-2, pi-cm5-3)                              │
│ └── Storage Worker (Beelink ME mini N150)                      │
│     ├── K3s Worker Node                                        │
│     ├── Longhorn Storage Provider                              │
│     └── 6x M.2 SSD slots (up to 24TB)                         │
└─────────────────────────────────────────────────────────────────┘
           │
           │ (S3 backups via Longhorn)
           ▼
┌─────────────────────────────────────────┐
│ NAS Node (pi-cm5-4) - Outside Cluster  │
│ ├── MinIO S3 Service                   │
│ └── 2TB Storage for backups            │
└─────────────────────────────────────────┘
```

## Current Status ✓

- [x] Base Pi CM5 configuration (`pi-base-config.yml`)
- [x] Storage configuration for NAS (`pi-storage-config.yml`)
- [x] System upgrades and security updates
- [x] Master orchestration playbook (`site.yml`)
- [x] Makefile automation
- [x] **Phase 4a: NAS Disk Preparation** - XFS formatted, mounted, ready for MinIO

## Execution Steps

### Phase 1: Current Infrastructure Setup ✓

**Command:** `make site-check` (dry-run) then `make site`

**What it does:**
1. Applies base Pi CM5 configuration to all Pi nodes
2. Configures PCIe/storage settings on NAS node
3. Updates all systems and configures unattended upgrades

**Test Requirements:**
- [ ] All Pi nodes respond to SSH
- [ ] PCIe enabled on NAS node: `lspci` shows devices
- [ ] System updates applied: `apt list --upgradable` shows no pending updates
- [ ] Unattended upgrades configured: Check `/etc/apt/apt.conf.d/50unattended-upgrades`

**Post-Phase 1:** Reboot all nodes to apply configuration changes

---

### Phase 2: K3s Cluster Setup (FUTURE)

**Planned Approach:** Adapt Jeff Geerlingguy's pi-cluster repository
- Reference: https://github.com/geerlingguy/pi-cluster

**Playbook to Create:** `k3s-cluster.yml`

**What it will do:**
1. Install K3s on control plane (pi-cm5-1)
2. Join worker nodes (pi-cm5-2, pi-cm5-3, Beelink) to cluster
3. Configure kubeconfig access

**Test Requirements:**
- [ ] `kubectl get nodes` shows all 4 nodes Ready
- [ ] `kubectl get pods -A` shows system pods running
- [ ] Control plane accessible from management machine
- [ ] All nodes have proper taints/labels

---

### Phase 3: Longhorn Distributed Storage (FUTURE)

**Playbook to Create:** `longhorn-storage.yml`

**What it will do:**
1. Install Longhorn via Helm/kubectl on K3s cluster
2. Configure storage classes and replica settings
3. Set up backup target (MinIO S3)

**Test Requirements:**
- [ ] Longhorn UI accessible
- [ ] All nodes show as storage nodes with available space
- [ ] Test PVC creation and mounting
- [ ] Volume replicas distributed across nodes
- [ ] Backup destination configured

---

### Phase 4a: NAS Disk Preparation ✅

**Status:** COMPLETED

**What was accomplished:**
- XFS filesystems created on both 2TB drives using WWN identifiers
- Persistent mounts configured at `/mnt/minio-drive1` and `/mnt/minio-drive2`
- PCIe controller activated and M.2 SATA drives accessible
- Storage ready for MinIO installation

**Validation:**
- [x] Both drives (3.8TB total) mounted and accessible
- [x] XFS filesystems with MINIODRIVE1/MINIODRIVE2 labels
- [x] Persistent `/etc/fstab` entries using stable disk labels
- [x] PCIe SATA controller detected and operational

---

### Phase 4b: MinIO S3 Backup Service (NEXT)

**Playbook to Create:** `minio-setup.yml`

**External Role:** `ricsanfre.minio` (to be added to requirements.yml)

**What it will do:**
1. Install MinIO using the ricsanfre.minio Ansible role
2. Configure MinIO with prepared storage paths:
   - `/mnt/minio-drive1/data`
   - `/mnt/minio-drive2/data`
3. Set up S3 buckets for Longhorn backups
4. Configure access keys and policies

**Test Requirements:**
- [ ] MinIO console accessible (web UI)
- [ ] S3 API responding to requests
- [ ] Backup bucket created with proper policies
- [ ] Test S3 operations (put/get objects)

---

### Phase 5: Integration & Monitoring (FUTURE)

**Playbook to Create:** `cluster-integration.yml`

**What it will do:**
1. Configure Longhorn → MinIO backup integration
2. Set up scheduled backups
3. Configure monitoring and alerting
4. Deploy sample applications for testing

**Test Requirements:**
- [ ] Scheduled backups working
- [ ] Sample app can use persistent storage
- [ ] Monitoring dashboards showing cluster health
- [ ] Disaster recovery test successful

---

## Current Infrastructure Commands

```bash
# Preview all changes
make site-check

# Apply full infrastructure setup
make site

# Individual playbook testing
make pi-base-config    # Dry-run base config
make pi-storage-config # Apply storage config
make upgrade           # System updates
```

## Hardware Configuration

### Current Devices
- **pi-cm5-1**: K3s control plane
- **pi-cm5-2**: K3s worker
- **pi-cm5-3**: K3s worker
- **pi-cm5-4**: MinIO NAS (2TB storage)

### Future Device
- **Beelink ME mini N150**: K3s storage worker
  - 6x M.2 SSD slots (up to 24TB)
  - Dual 2.5G networking
  - Will run both K3s worker + Longhorn storage

## Notes

- All Pi CM5 devices configured for headless operation with power optimization
- NAS node has PCIe enabled for M.2 SATA controller support
- Cluster nodes have PCIe disabled for power savings
- Security updates configured for automatic installation with 2AM reboot window
- Using UV for Python dependency management and Ansible collections
