# Home Lab Infrastructure TODO

## Overview

Complete home lab infrastructure with K3s Kubernetes cluster, Longhorn distributed storage, and MinIO S3 backup service with secure remote access.

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ K3s Cluster (Tailscale Mesh)                                   │
│ ├── Control Plane (pi-cm5-1)                                   │
│ ├── Workers (pi-cm5-2, pi-cm5-3)                              │
│ └── Storage Worker (Beelink ME mini N150 - future)            │
│     ├── K3s Worker Node                                        │
│     ├── Longhorn Storage Provider                              │
│     └── 6x M.2 SSD slots (up to 24TB)                         │
└─────────────────────────────────────────────────────────────────┘
           │ (Encrypted S3 backups via Tailscale VPN)
           ▼
┌─────────────────────────────────────┐
│ Offsite NAS (pi-cm5-4)             │
│ ├── MinIO S3 (HTTPS + SSE)         │
│ ├── 2TB XFS Storage                │
│ └── Tailscale VPN Access           │
└─────────────────────────────────────┘
```

## Completed Infrastructure ✅

### Phase 1: Base Configuration
- **Status:** ✅ Complete
- **Command:** `make site`
- **Accomplished:** Pi CM5 base config, PCIe/storage settings, system updates, unattended upgrades

### Phase 4a: NAS Storage Preparation
- **Status:** ✅ Complete
- **Accomplished:** XFS filesystems on 2TB drives, persistent mounts, PCIe SATA controller active

### Phase 4b: MinIO S3 Service
- **Status:** ✅ Complete
- **Command:** `make minio-setup`
- **Accomplished:** MinIO deployed with buckets (longhorn-backups, cluster-logs, media-storage)
- **Access:** http://pi-cm5-4.local:9001 (console), http://pi-cm5-4.local:9000 (API)
- **Usage Guide:** See `docs/minio-usage.md`

### Phase 5a: Ansible Vault Setup
- **Status:** ✅ Complete
- **Command:** Built-in vault functionality
- **Accomplished:** Encrypted credential management with vault password files, MinIO/K3s credentials secured
- **Security Impact:** All infrastructure credentials now encrypted at rest with AES256

### Phase 6: K3s Cluster Setup
- **Status:** ✅ Complete
- **Command:** `make k3s-cluster` or included in `make site`
- **Accomplished:**
  - 3-node HA K3s cluster with embedded etcd consensus
  - Staggered maintenance schedules for zero-downtime updates (02:00, 02:30, 03:00)
  - Production-ready configuration with proper networking (Flannel VXLAN)
  - Comprehensive uninstall playbook for debugging and clean reinstalls
- **Access:** kubectl via any cluster node (pi-cm5-1, pi-cm5-2, pi-cm5-3)
- **Documentation:** See `docs/k3s-cluster-setup.md`, `docs/k3s-maintenance-guide.md`

### Phase 6b: Kubernetes Applications (NEEDS WORK)
- **Status:** ⚠️ Problematic - Currently commented out of site.yml
- **Issue:** k8s-applications playbook has issues and needs debugging/testing
- **Command:** `make k8s-apps` (when fixed)
- **Note:** Excluded from `make site` until properly tested and verified

---

## Remaining Phases


### Phase 5b: pfSense HAProxy Load Balancer & SSL/TLS Certificates

**Purpose:** Enable external access and automated HTTPS certificates using pfSense HAProxy, dramatically simplifying K3s cluster architecture

**Why pfSense-Centric Approach:**
- **Simplified K3s**: Re-enable Traefik and ServiceLB for internal routing only
- **Enterprise-Grade HA**: HAProxy monitors all 3 K3s nodes with health checks
- **Centralized SSL**: ACME package handles Let's Encrypt certificates at router level
- **No Single Point of Failure**: Unlike MetalLB approach, pfSense distributes across all nodes
- **Performance**: SSL termination at network edge reduces K3s resource usage

**Architecture:**
```
Internet → pfSense HAProxy → K3s Nodes (HTTP internal)
           ├── SSL Termination (Let's Encrypt ACME)
           ├── Load Balancing (All 3 nodes)
           ├── Health Checks (/healthz)
           └── Host-based Routing
```

**Implementation Strategy:**

**Step 1: pfSense Package Installation**
- Install **HAProxy package** for load balancing and SSL termination
- Install **ACME package** for automated Let's Encrypt certificate management
- Configure global settings and enable stats monitoring

**Step 2: Certificate Management (pfSense ACME + Cloudflare)**
- Configure ACME account with Let's Encrypt production
- Set up Cloudflare DNS-01 validation with API token
- Generate wildcard certificate `*.jardoole.xyz` with auto-renewal

**Step 3: HAProxy Backend Configuration**
- Create **K3s cluster backend** with all 3 nodes (pi-cm5-1,2,3:80)
- Create **MinIO backend** with NAS node (pi-cm5-4:9001)
- Configure HTTP health checks using `/healthz` endpoint
- Set up round-robin load balancing with automatic failover

**Step 4: HAProxy Frontend Configuration**
- Configure HTTPS frontend (port 443) with SSL termination
- Set up host-based routing:
  - `minio.jardoole.xyz` → MinIO backend
  - `api.jardoole.xyz` → MinIO backend
  - Default → K3s cluster backend
- Configure HTTP→HTTPS redirect (port 80)

**Step 5: K3s Cluster Simplification**
- **Re-enable Traefik** in K3s configuration (remove from disable list)
- **Re-enable ServiceLB** in K3s configuration (remove from disable list)
- Keep internal routing simple with built-in components

**Files to Create:**
- ✅ `docs/pfsense-haproxy-setup.md` - Complete pfSense configuration guide
- `docs/pfsense-integration-architecture.md` - Architecture documentation
- ✅ `group_vars/cluster/k3s.yml` - Updated to re-enable Traefik/ServiceLB
- `playbooks/k3s-reconfigure.yml` - Apply simplified K3s configuration

**Test Requirements:**
- [ ] pfSense HAProxy package installed and configured
- [ ] ACME wildcard certificate `*.jardoole.xyz` issued and renewable
- [ ] HAProxy health checks showing all K3s nodes as UP
- [ ] Load balancing functional across all 3 K3s nodes
- [ ] SSL termination working at pfSense level
- [ ] MinIO console accessible via https://minio.jardoole.xyz
- [ ] MinIO API accessible via https://api.jardoole.xyz
- [ ] Automatic failover when K3s nodes go down
- [ ] K3s Traefik dashboard accessible internally

**Eliminated Components:**
- ❌ **MetalLB** - pfSense HAProxy handles external load balancing
- ❌ **NGINX Ingress** - pfSense HAProxy does SSL termination
- ❌ **cert-manager** - pfSense ACME handles certificates

**Security Benefits:**
- **SSL termination at network edge** - Better security boundary
- **Automatic certificate renewal** - No expiration outages
- **Health monitoring** - Automatic failover on node failure
- **Centralized certificate management** - Single point of control

**Dependencies:** Phase 5a ✅ (Vault for Cloudflare API token)

**Links:**
- ✅ [pfSense HAProxy Setup Guide](docs/pfsense-haproxy-setup.md)
- [pfSense ACME Documentation](https://docs.netgate.com/pfsense/en/latest/packages/acme/)
- [HAProxy Health Checks](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/reliability/health-checks/)

---

### Phase 5c: MinIO Server-Side Encryption (SSE)

**Purpose:** Enable MinIO native encryption for sensitive buckets

**Implementation:**
- Configure MinIO Key Encryption Service (KES)
- Enable SSE-KMS for longhorn-backups and cluster-logs buckets
- Set up encryption key management and rotation
- Keep media-storage unencrypted for performance

**Files to Create:**
- `playbooks/minio-encryption.yml` - SSE configuration
- `group_vars/nas/encryption.yml` - Encryption settings
- KES configuration and key storage

**Test Requirements:**
- [ ] KES service configured and running
- [ ] Sensitive buckets encrypted with SSE-KMS
- [ ] Encrypted/unencrypted bucket operations functional
- [ ] Encryption keys secured in vault

**Dependencies:** Phase 5b (SSL required for MinIO SSE)

**Links:**
- [MinIO Server-Side Encryption](https://min.io/docs/minio/linux/operations/server-side-encryption.html)
- [MinIO KES Documentation](https://github.com/minio/kes)

---

### Phase 5d: Tailscale VPN Network

**Purpose:** Secure remote access to offsite NAS without port forwarding

**Implementation:**
- Install Tailscale on all Pi nodes (cluster + NAS)
- Configure auth keys and Access Control Lists (ACLs)
- Set up subnet routing for cluster network access
- Integrate with existing services (MinIO, SSH, future K3s)

**Network Architecture:**
```
Management Device → Tailscale Mesh → [Cluster Nodes + Offsite NAS]
```

**Files to Create:**
- `playbooks/tailscale-setup.yml` - Installation and configuration
- `group_vars/all/tailscale.yml` - Network configuration
- `templates/tailscale-acl.json.j2` - Access control template

**Test Requirements:**
- [ ] All Pi nodes connected to Tailscale mesh
- [ ] MinIO accessible via Tailscale IPs/DNS
- [ ] ACLs restricting access appropriately
- [ ] Management device can access all services

**Dependencies:** Phase 5a (Vault for auth keys)

**Links:**
- [Tailscale Documentation](https://tailscale.com/kb/)
- [K3s Tailscale Integration](https://docs.k3s.io/networking/distributed-multicloud)

---

### Phase 5e: UFW Firewall Configuration

**Purpose:** Defense-in-depth network security for all nodes

**Implementation:**
- Install UFW on all Pi nodes with node-specific rules
- Configure SSH rate limiting and Tailscale mesh allowance
- Set up K3s networking ports (API, etcd, Flannel VXLAN)
- Enable logging and security monitoring

**⚠️ K3s Firewall Considerations:**
K3s recommends disabling firewalls due to networking complexity. We maintain firewalls for security but require careful configuration of Flannel VXLAN (UDP 8472) and pod/service networks (10.42.0.0/16, 10.43.0.0/16).

**Files to Create:**
- `playbooks/firewall-config.yml` - UFW configuration
- `group_vars/cluster/firewall.yml` - K3s firewall rules
- `group_vars/nas/firewall.yml` - MinIO firewall rules

**Test Requirements:**
- [ ] UFW active with SSH rate limiting functional
- [ ] Tailscale mesh traffic allowed
- [ ] K3s ports configured for future cluster setup
- [ ] Flannel VXLAN (UDP 8472) connectivity verified

**Dependencies:** Phase 5d (Tailscale must be configured first)

**Links:**
- [K3s Firewall Troubleshooting](docs/k3s-firewall-troubleshooting.md) ← Already created

---


### Phase 7: Longhorn Distributed Storage

**Purpose:** Distributed block storage with encrypted MinIO backups

**Implementation:**
- Install Longhorn via Helm on K3s cluster
- Configure storage classes and replica settings
- Set up encrypted backup target (MinIO S3 with SSE)
- Configure backup schedules and retention policies

**Files to Create:**
- `playbooks/longhorn-storage.yml` - Longhorn installation
- Longhorn backup configuration for encrypted MinIO

**Test Requirements:**
- [ ] Longhorn UI accessible via K3s ingress
- [ ] All nodes registered as storage nodes
- [ ] PVC creation and mounting functional
- [ ] Encrypted backups to MinIO working

**Dependencies:** Phase 6 ✅ (K3s cluster - Complete), Phase 5c (MinIO encryption)

**Links:**
- [Longhorn Documentation](https://longhorn.io/docs/)
- [Longhorn S3 Backup Setup](https://longhorn.io/docs/latest/snapshots-and-backups/backup-and-restore/set-backup-target/)

---

## Quick Reference

### Current Commands
```bash
# Infrastructure management
make site-check         # Preview all changes
make site               # Apply base infrastructure (includes MinIO + K3s parallel)
make minio              # Deploy MinIO S3 service standalone
make k3s-cluster        # Deploy K3s HA cluster standalone
make k3s-uninstall      # Uninstall K3s for debugging
make teardown           # Complete infrastructure removal
make upgrade            # System updates

# Development
make setup              # Install dependencies
make lint               # Run linting and syntax checks
make precommit          # Pre-commit hooks
```

### Hardware Configuration
- **pi-cm5-1**: K3s control plane ✅ (HA cluster running)
- **pi-cm5-2, pi-cm5-3**: K3s workers ✅ (HA cluster running)
- **pi-cm5-4**: MinIO NAS ✅ (2TB XFS storage, offsite via Tailscale)
- **Beelink ME mini N150** (future): K3s storage worker with Longhorn (6x M.2, up to 24TB)

### Phase Dependencies
```
5a (Vault) → 5b (SSL) → 5c (MinIO Encryption)
            ↓
5d (Tailscale) → 5e (Firewall) → 6 (K3s) ✅ → 7 (Longhorn)
```

### Key Resources
- **Project Structure:** `docs/project-structure.md`
- **Git Guidelines:** `docs/git-commit-guidelines.md`
- **MinIO Usage:** `docs/minio-usage.md`
- **K3s Setup:** `docs/k3s-cluster-setup.md`
- **K3s Maintenance:** `docs/k3s-maintenance-guide.md`
- **K3s Firewall:** `docs/k3s-firewall-troubleshooting.md`
