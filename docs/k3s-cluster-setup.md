# K3s HA Cluster Setup Documentation

## Overview

This document describes the current K3s High Availability cluster implementation using 3 Raspberry Pi CM5 nodes with embedded etcd.

**Cluster Details:**
- **Nodes**: pi-cm5-1, pi-cm5-2, pi-cm5-3 (all control-plane + etcd + master roles)
- **Version**: K3s v1.31.3+k3s1 (stable)
- **Architecture**: ARM64 (Pi CM5)
- **Storage**: 64GB eMMC per node
- **Networking**: Flannel VXLAN backend

## Architecture

### High Availability Design
- **3-node etcd cluster** providing consensus and fault tolerance
- **No single point of failure** - any node can handle API requests
- **Staggered maintenance** - nodes restart at different times (02:00, 02:30, 03:00)

### Network Configuration
- **Cluster CIDR**: 10.42.0.0/16 (pod networking)
- **Service CIDR**: 10.43.0.0/16 (service networking)
- **Flannel Backend**: VXLAN (UDP port 8472)
- **API Server**: Port 6443 on all nodes

## File Structure

```
home-lab/
├── group_vars/k3s_cluster/k3s.yml        # Global K3s configuration
├── host_vars/
│   ├── pi-cm5-1.yml                  # First node config (etcd init)
│   ├── pi-cm5-2.yml                  # Second node config
│   └── pi-cm5-3.yml                  # Third node config
├── playbooks/
│   ├── k3s-cluster.yml              # Main deployment playbook
│   └── k3s-uninstall.yml            # Cluster removal playbook
├── requirements.yml                  # Ansible dependencies
└── Makefile                          # Deployment commands
```

## Key Configuration Files

### 1. Global Configuration (`group_vars/k3s_cluster/k3s.yml`)

```yaml
# K3s version and configuration
k3s_release_version: v1.31.3+k3s1
k3s_become: true

# Cluster token for secure communication
k3s_control_token: "homelab-k3s-cluster-token-change-this"

# Main K3s server configuration
k3s_server:
  # Network configuration
  cluster-cidr: "10.42.0.0/16"
  service-cidr: "10.43.0.0/16"
  flannel-backend: "vxlan"

  # Disable components (using alternatives later)
  disable:
    - traefik    # Will use different ingress controller
    - servicelb  # Will use MetalLB

  # Node labels
  node-label:
    - "node.kubernetes.io/instance-type=pi-cm5"
    - "topology.kubernetes.io/zone=homelab"

  # Storage and logging
  default-local-storage-path: "/var/lib/rancher/k3s/storage"
  log: "/var/log/k3s.log"
  alsologtostderr: false
  v: 1  # Minimal logging
```

### 2. Node-Specific Configuration

Each node has specific settings for HA sequencing:

**pi-cm5-1 (First Node)**:
```yaml
# Initializes the etcd cluster
k3s_control_node: true
k3s_etcd_datastore: true
unattended_automatic_reboot_time: "02:00"
```

**pi-cm5-2 & pi-cm5-3 (Joining Nodes)**:
```yaml
# Joins existing etcd cluster
k3s_control_node: true
k3s_etcd_datastore: true
unattended_automatic_reboot_time: "02:30" # pi-cm5-2
unattended_automatic_reboot_time: "03:00" # pi-cm5-3
```

## Deployment Process

### Prerequisites
1. All Pi nodes properly configured with cgroups enabled
2. Ansible and dependencies installed (`make setup`)
3. SSH access configured to all nodes

### Deployment Commands

```bash
# Full cluster deployment
make k3s-cluster

# Dry-run check before deployment
make k3s-cluster-check

# Complete cluster removal (for debugging/redeploy)
make k3s-uninstall
```

### Deployment Sequence

The xanmanning.k3s role handles proper sequencing:

1. **Pre-checks**: Version compatibility, cgroups, prerequisites
2. **First node** (pi-cm5-1): Initializes etcd cluster with `k3s_etcd_datastore: true`
3. **Additional nodes**: Join existing etcd cluster automatically
4. **Verification**: All nodes become Ready with control-plane,etcd,master roles

## Troubleshooting History

### Issues Encountered & Solutions

1. **"Too many learner members" Error**
   - **Cause**: All nodes trying to initialize etcd simultaneously
   - **Solution**: Use proper `k3s_etcd_datastore` configuration instead of manual `cluster-init`

2. **Feature Gate Error**
   - **Cause**: `LocalStorageCapacityIsolation` removed in K8s 1.31
   - **Solution**: Removed deprecated feature gate from configuration

3. **Version Instability**
   - **Cause**: Auto-selection picked unreleased v1.33.3+k3s1
   - **Solution**: Pinned to stable `k3s_release_version: v1.31.3+k3s1`

4. **Sequential Startup Issues**
   - **Cause**: xanmanning.k3s role complexity with multiple nodes
   - **Solution**: Single playbook run with proper host_vars configuration

## Current Status

### ✅ Working Features
- 3-node HA cluster with etcd consensus
- All system pods running (CoreDNS, metrics-server, local-path-provisioner)
- API server accessible from all nodes
- Proper node labeling and roles
- Staggered maintenance windows
- Clean uninstall capability

### ⚠️ Configuration Complexity
- Multiple configuration files (group_vars + 3x host_vars)
- Custom role parameter handling
- Non-standard deployment sequence
- Manual troubleshooting required for issues

## Maintenance

### Routine Operations

**Check Cluster Health**:
```bash
# From any control node
sudo kubectl get nodes -o wide --kubeconfig /etc/rancher/k3s/k3s.yaml
sudo kubectl get pods -A --kubeconfig /etc/rancher/k3s/k3s.yaml
sudo kubectl cluster-info --kubeconfig /etc/rancher/k3s/k3s.yaml
```

**Service Status**:
```bash
# Check all nodes
ansible cluster -m shell -a "systemctl is-active k3s"
```

**Logs**:
```bash
# Check specific node
ansible pi-cm5-1 -m shell -a "journalctl -u k3s --since='1 hour ago' --no-pager"
```

### Backup Considerations
- **etcd data**: Located in `/var/lib/rancher/k3s/server/db/etcd/`
- **Cluster config**: `/etc/rancher/k3s/k3s.yaml`
- **Cluster token**: `/var/lib/rancher/k3s/server/token`

## Next Steps

### Phase 7: Networking & Ingress
- Install MetalLB for LoadBalancer services
- Configure ingress controller (nginx/traefik)
- Setup TLS certificates with cert-manager

### Migration Evaluation
Compare current setup with Jeff Geerling's pi-cluster approach:
- Configuration complexity
- Maintenance overhead
- Community support
- Upgrade procedures

## Dependencies

### Ansible Requirements (`requirements.yml`)
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"

roles:
  - name: xanmanning.k3s
```

### Make Targets
```makefile
k3s-cluster:           # Deploy K3s HA cluster
k3s-cluster-check:     # Dry-run deployment check
k3s-uninstall:         # Remove cluster completely
```

---

**Documentation Date**: 2025-08-25
**K3s Version**: v1.31.3+k3s1
**Deployment Method**: xanmanning.k3s Ansible role
**Status**: ✅ Production Ready
