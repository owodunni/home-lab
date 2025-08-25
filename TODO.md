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

---

## Remaining Phases

### Phase 5a: Ansible Vault Setup

**Purpose:** Secure credential management for infrastructure secrets

**Implementation:**
- Create vault files for MinIO credentials, Cloudflare API tokens, SSL keys
- Update existing group_vars to use encrypted vault variables
- Configure vault password files with proper permissions (600)

**Files to Create:**
- `group_vars/nas/vault.yml` - MinIO encrypted credentials
- `group_vars/all/vault.yml` - Global encrypted variables
- `vault_passwords/` directory - Password files (gitignored)

**Test Requirements:**
- [ ] Vault files encrypted with AES256
- [ ] Existing playbooks work with vault variables
- [ ] Git repository contains no plaintext credentials

**Dependencies:** None - foundational security requirement

---

### Phase 5b: SSL/TLS Certificates (Certbot + Cloudflare)

**Purpose:** Automated HTTPS certificates for MinIO using Let's Encrypt + DNS-01 challenges

**Implementation:**
- Install certbot and certbot-dns-cloudflare plugin
- Configure Cloudflare API token for DNS automation
- Generate certificates for MinIO domains (minio.domain.com, console.domain.com)
- Set up automatic renewal via systemd timers
- Update MinIO configuration for TLS

**Files to Create:**
- `playbooks/ssl-certificates.yml` - Certificate management playbook
- `group_vars/nas/ssl.yml` - SSL configuration
- Update MinIO service config for HTTPS

**Test Requirements:**
- [ ] SSL certificates generated for MinIO domains
- [ ] MinIO console/API accessible via HTTPS
- [ ] Certificate renewal timer active
- [ ] DNS-01 challenges working automatically

**Dependencies:** Phase 5a (Vault for API tokens)

**Links:**
- [Certbot DNS Cloudflare Plugin](https://certbot-dns-cloudflare.readthedocs.io/)
- [Let's Encrypt DNS Validation](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)

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

### Phase 6: K3s Cluster Setup

**Purpose:** Kubernetes cluster with Tailscale mesh networking

**Implementation:**
- Install K3s on control plane (pi-cm5-1) with Tailscale integration
- Join worker nodes via Tailscale mesh network
- Configure cross-site communication for offsite nodes
- Set up kubeconfig access over secure network

**Files to Create:**
- `playbooks/k3s-cluster.yml` - Cluster installation
- `group_vars/cluster/k3s.yml` - K3s configuration

**Test Requirements:**
- [ ] All cluster nodes show Ready status
- [ ] System pods running across all nodes
- [ ] kubectl access via Tailscale network
- [ ] Cross-site pod communication functional

**Dependencies:** Phase 5e (Firewall must allow K3s traffic)

**Links:**
- [Jeff Geerlingguy pi-cluster](https://github.com/geerlingguy/pi-cluster)
- [K3s Installation Guide](https://docs.k3s.io/quick-start)

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

**Dependencies:** Phase 6 (K3s cluster), Phase 5c (MinIO encryption)

**Links:**
- [Longhorn Documentation](https://longhorn.io/docs/)
- [Longhorn S3 Backup Setup](https://longhorn.io/docs/latest/snapshots-and-backups/backup-and-restore/set-backup-target/)

---

## Quick Reference

### Current Commands
```bash
# Infrastructure management
make site-check         # Preview all changes
make site               # Apply base infrastructure
make minio-setup        # Deploy MinIO S3 service
make upgrade            # System updates

# Development
make setup              # Install dependencies
make lint               # Run linting and syntax checks
make precommit          # Pre-commit hooks
```

### Hardware Configuration
- **pi-cm5-1**: K3s control plane
- **pi-cm5-2, pi-cm5-3**: K3s workers
- **pi-cm5-4**: MinIO NAS (2TB XFS storage, offsite via Tailscale)
- **Beelink ME mini N150** (future): K3s storage worker with Longhorn (6x M.2, up to 24TB)

### Phase Dependencies
```
5a (Vault) → 5b (SSL) → 5c (MinIO Encryption)
            ↓
5d (Tailscale) → 5e (Firewall) → 6 (K3s) → 7 (Longhorn)
```

### Key Resources
- **Project Structure:** `docs/project-structure.md`
- **Git Guidelines:** `docs/git-commit-guidelines.md`
- **MinIO Usage:** `docs/minio-usage.md`
- **K3s Firewall:** `docs/k3s-firewall-troubleshooting.md`
