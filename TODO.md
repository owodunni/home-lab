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
- **Command:** `make k3s-cluster`
- **Accomplished:**
  - 3-node HA K3s cluster with embedded etcd consensus
  - Staggered maintenance schedules for zero-downtime updates (02:00, 02:30, 03:00)
  - Production-ready configuration with proper networking (Flannel VXLAN)
  - Comprehensive uninstall playbook for debugging and clean reinstalls
- **Access:** kubectl via any cluster node (pi-cm5-1, pi-cm5-2, pi-cm5-3)
- **Documentation:** See `docs/k3s-cluster-setup.md`, `docs/k3s-maintenance-guide.md`

---

## Remaining Phases


### Phase 5b: Load Balancer Infrastructure & SSL/TLS Certificates

**Purpose:** Enable external access and automated HTTPS certificates for both K3s cluster and MinIO

**Why This Is Essential:**
- **External Access**: Currently no way to reach services from outside the home network - need port forwarding + load balancer
- **Certificate Management**: Manual certificate renewal leads to service outages when certs expire
- **Production Security**: HTTPS required for secure remote access and API operations
- **DNS-01 Advantages**: Allows certificates for internal services that aren't publicly accessible
- **Wildcard Certificates**: Single cert covers multiple subdomains, reduces management overhead

**Implementation Strategy:**

**Step 1: Port Forwarding Setup (Router Configuration)**
*Why First:* Need external connectivity to test certificate validation and service access
- Forward port 443 (HTTPS) from router to K3s cluster load balancer IP
- Forward port 80 (HTTP) for Let's Encrypt HTTP-01 challenges as fallback
- Document router-specific steps for future reference

**Step 2: K3s Load Balancer Infrastructure**
*Why Needed:* K3s has Traefik and ServiceLB disabled - need alternatives for external access
- Deploy **MetalLB** for LoadBalancer services (provides external IPs within home network)
- Deploy **NGINX Ingress Controller** for HTTP/HTTPS routing and SSL termination
- Configure MetalLB IP pool from available 192.168.0.x subnet range
- Enables multiple services to share port 443 with host-based routing

**Step 3: Certificate Management (cert-manager + Cloudflare)**
*Why cert-manager over certbot:* Native K8s integration, automatic renewal, better secret management
- Deploy **cert-manager** on K3s cluster for automated certificate lifecycle
- Configure **Cloudflare DNS-01 issuer** with API token for DNS challenges
- Generate certificates for:
  - `minio.jardoole.xyz` (MinIO console access)
  - `api.jardoole.xyz` (MinIO API endpoint)
  - `*.jardoole.xyz` (wildcard for future services - Longhorn UI, monitoring, etc.)

**Step 4: MinIO HTTPS Configuration**
*Why Separate:* MinIO runs on NAS node outside K3s cluster, needs direct TLS configuration
- Update MinIO service configuration for HTTPS endpoints
- Configure certificate paths and automatic renewal integration
- Maintain backward compatibility with existing bucket configurations

**Files to Create:**
- `playbooks/port-forwarding-guide.yml` - Documentation and validation
- `playbooks/load-balancer-setup.yml` - MetalLB + NGINX ingress
- `playbooks/ssl-certificates.yml` - cert-manager + Cloudflare configuration
- `group_vars/cluster/metallb.yml` - IP pools and MetalLB config
- `group_vars/cluster/nginx-ingress.yml` - Ingress controller settings
- `group_vars/cluster/cert-manager.yml` - Certificate issuers and policies
- `group_vars/nas/ssl.yml` - MinIO SSL configuration

**Test Requirements:**
- [ ] External port forwarding functional (443 → cluster)
- [ ] MetalLB assigns external IPs to LoadBalancer services
- [ ] NGINX ingress routes traffic based on hostnames
- [ ] cert-manager creates certificates via Cloudflare DNS-01
- [ ] Wildcard certificate *.jardoole.xyz issued and renewable
- [ ] MinIO console accessible via https://minio.jardoole.xyz
- [ ] MinIO API accessible via https://api.jardoole.xyz
- [ ] Certificate auto-renewal working (test with short-lived staging certs)

**Security Benefits:**
- **Internal Service Certificates**: DNS-01 enables HTTPS for services not exposed to internet
- **Wildcard Coverage**: Future services (Longhorn, monitoring) automatically secured
- **Automated Renewal**: Eliminates certificate expiration outages
- **API Token Security**: Cloudflare token stored in Ansible Vault, not plaintext

**Dependencies:** Phase 5a ✅ (Vault for API tokens)

**Links:**
- [cert-manager Cloudflare Issuer](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
- [MetalLB Configuration](https://metallb.universe.tf/configuration/)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)

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
make site               # Apply base infrastructure
make minio-setup        # Deploy MinIO S3 service
make k3s-cluster        # Deploy K3s HA cluster
make k3s-uninstall      # Uninstall K3s for debugging
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
