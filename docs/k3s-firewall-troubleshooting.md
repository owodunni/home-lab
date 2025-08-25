# K3s Firewall Troubleshooting Guide

This guide documents troubleshooting procedures for running K3s with UFW firewall enabled, addressing the challenges identified in [K3s documentation](https://docs.k3s.io/installation/requirements#operating-systems) regarding firewall compatibility.

## Overview

K3s officially recommends disabling firewalls due to networking complexity. However, our infrastructure maintains firewalls for defense-in-depth security. This document provides procedures to resolve common issues when running K3s with UFW active.

## Pre-Installation Setup

### Required Firewall Rules

Before installing K3s, ensure these UFW rules are configured:

```bash
# Basic K3s communication ports
ufw allow 6443/tcp comment "K3s API server"
ufw allow 10250/tcp comment "kubelet API"
ufw allow 2379:2380/tcp comment "etcd client/peer"

# Critical: Flannel VXLAN overlay networking
ufw allow 8472/udp comment "Flannel VXLAN"

# K3s internal networks (adjust CIDRs as needed)
ufw allow from 10.42.0.0/16 comment "K3s pod network"
ufw allow from 10.43.0.0/16 comment "K3s service network"

# Metrics and health checks
ufw allow 10254/tcp comment "K3s metrics server"

# NodePort range (if using NodePort services)
ufw allow 30000:32767/tcp comment "NodePort services"
```

### Verify UFW Configuration

```bash
# Check UFW status and rules
ufw status numbered

# Verify Flannel VXLAN rule is present
ufw status | grep 8472

# Test UDP connectivity between nodes (before K3s installation)
nc -u -l 8472  # on one node
nc -u <node-ip> 8472  # from another node
```

## Installation Issues

### Problem: K3s Installation Hangs

**Symptoms:**
- Installation command hangs indefinitely
- No error messages, process appears frozen
- Timeout after 10+ minutes

**Root Cause:**
UFW blocking required network communication during cluster bootstrap.

**Solution:**
1. **Temporary UFW disable** (if safe to do so):
   ```bash
   # Disable UFW temporarily
   ufw --force disable

   # Install K3s
   curl -sfL https://get.k3s.io | sh -

   # Re-enable UFW after successful installation
   ufw --force enable
   ```

2. **Alternative: Install with network policy disabled**:
   ```bash
   # Install K3s without NetworkPolicy initially
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable-network-policy" sh -
   ```

3. **Debug installation**:
   ```bash
   # Run installation with debug logging
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--debug" sh -

   # Check systemd logs
   journalctl -u k3s -f
   ```

### Problem: K3s Service Fails to Start

**Symptoms:**
- K3s installation completes but service won't start
- Error: "Failed to start k3s"
- systemd shows failed status

**Diagnosis:**
```bash
# Check service status
systemctl status k3s

# View detailed logs
journalctl -u k3s --since "5 minutes ago"

# Check for firewall-related errors
grep -i "connection refused\|timeout\|network" /var/log/syslog
```

**Common Solutions:**
1. **Flannel VXLAN blocked**:
   ```bash
   # Verify UDP 8472 is allowed
   ufw status | grep 8472

   # Add rule if missing
   ufw allow 8472/udp comment "Flannel VXLAN"
   ```

2. **etcd communication blocked** (control plane nodes):
   ```bash
   # Ensure etcd ports are open
   ufw allow 2379:2380/tcp comment "etcd client/peer"
   ```

## Runtime Networking Issues

### Problem: Pods Can't Communicate

**Symptoms:**
- Pods stuck in `Pending` or `ContainerCreating` state
- DNS resolution failures inside pods
- Inter-pod communication timeouts

**Diagnosis:**
```bash
# Check pod status
kubectl get pods --all-namespaces

# Describe problematic pods
kubectl describe pod <pod-name> -n <namespace>

# Check Flannel status
kubectl get pods -n kube-flannel

# Test pod-to-pod networking
kubectl exec -it <pod1> -- ping <pod2-ip>
```

**Solutions:**
1. **Pod network CIDR issues**:
   ```bash
   # Verify K3s pod CIDR (default: 10.42.0.0/16)
   kubectl cluster-info dump | grep -i "cluster-cidr"

   # Update UFW rule to match actual CIDR
   ufw delete allow from 10.42.0.0/16
   ufw allow from <actual-pod-cidr> comment "K3s pod network"
   ```

2. **Service network blocked**:
   ```bash
   # Check K3s service CIDR (default: 10.43.0.0/16)
   kubectl cluster-info dump | grep -i "service-cluster-ip-range"

   # Add/update service network rule
   ufw allow from <service-cidr> comment "K3s service network"
   ```

### Problem: LoadBalancer Services Not Accessible

**Symptoms:**
- LoadBalancer services show `<pending>` external IP
- Services accessible from within cluster but not externally
- Connection refused from outside the node

**Diagnosis:**
```bash
# Check LoadBalancer service status
kubectl get svc -o wide

# Check if MetalLB/ServiceLB is configured
kubectl get pods -n metallb-system  # if using MetalLB
kubectl get svc -n kube-system | grep svclb  # K3s ServiceLB
```

**Solutions:**
1. **NodePort range blocked**:
   ```bash
   # Ensure NodePort range is open (30000-32767)
   ufw allow 30000:32767/tcp comment "NodePort services"
   ```

2. **LoadBalancer IP range**:
   ```bash
   # If using external LoadBalancer IPs, allow traffic
   ufw allow from <loadbalancer-ip-range>
   ```

## Advanced Troubleshooting

### Flannel VXLAN Debugging

**Test VXLAN connectivity manually:**

```bash
# On node 1 - create VXLAN interface
ip link add vxlan-test type vxlan id 100 group 239.1.1.1 dev eth0 dstport 8472
ip link set vxlan-test up
ip addr add 192.168.100.1/24 dev vxlan-test

# On node 2 - create matching VXLAN interface
ip link add vxlan-test type vxlan id 100 group 239.1.1.1 dev eth0 dstport 8472
ip link set vxlan-test up
ip addr add 192.168.100.2/24 dev vxlan-test

# Test connectivity
ping 192.168.100.2  # from node 1
ping 192.168.100.1  # from node 2

# Clean up
ip link del vxlan-test  # on both nodes
```

### UFW Logging and Analysis

**Enable UFW logging:**
```bash
# Enable UFW logging
ufw logging on

# View UFW logs
tail -f /var/log/ufw.log

# Filter for K3s-related traffic
grep -E "(8472|6443|10250)" /var/log/ufw.log
```

**Analyze blocked traffic:**
```bash
# Show blocked packets
grep "BLOCK" /var/log/ufw.log | tail -20

# Look for K3s port blocking
grep -E "DPT=(6443|8472|10250|2379|2380)" /var/log/ufw.log
```

### Network Namespace Debugging

**Check K3s networking namespaces:**
```bash
# List network namespaces
ip netns list

# Examine cni0 bridge
brctl show cni0

# Check Flannel interface
ip addr show flannel.1

# Verify routing table
route -n
```

## Emergency Procedures

### Complete Network Reset

If K3s networking is completely broken:

```bash
# 1. Stop K3s
systemctl stop k3s

# 2. Clean up network interfaces
ip link delete cni0
ip link delete flannel.1
iptables --flush
iptables --delete-chain

# 3. Reset UFW (backup rules first!)
ufw --force reset

# 4. Reconfigure UFW with minimal rules
ufw allow ssh
ufw allow 6443/tcp
ufw allow 8472/udp
ufw allow 10250/tcp
ufw --force enable

# 5. Restart K3s
systemctl start k3s

# 6. Verify functionality
kubectl get nodes
kubectl get pods --all-namespaces
```

### Firewall-Free Testing

For debugging, temporarily test without UFW:

```bash
# CAUTION: Only in secure environments!
ufw --force disable

# Test K3s functionality
kubectl get nodes
kubectl apply -f test-pod.yaml
kubectl exec -it test-pod -- ping google.com

# Re-enable firewall immediately after testing
ufw --force enable
```

## Monitoring and Alerting

### Key Metrics to Monitor

1. **UFW blocked packets** - High block rate may indicate misconfiguration
2. **K3s API server availability** - Port 6443 connectivity
3. **Flannel VXLAN traffic** - UDP 8472 packet flow
4. **Pod startup failures** - NetworkPolicy conflicts
5. **Service discovery issues** - DNS resolution in pods

### Automated Health Checks

```bash
#!/bin/bash
# k3s-firewall-health-check.sh

# Check UFW status
if ! ufw status | grep -q "Status: active"; then
    echo "CRITICAL: UFW is not active"
    exit 2
fi

# Check K3s API server
if ! curl -k -s https://localhost:6443/livez > /dev/null; then
    echo "CRITICAL: K3s API server not responding"
    exit 2
fi

# Check Flannel VXLAN interface
if ! ip addr show flannel.1 > /dev/null 2>&1; then
    echo "WARNING: Flannel VXLAN interface missing"
    exit 1
fi

# Check for recent UFW blocks of K3s traffic
if grep -E "(6443|8472|10250)" /var/log/ufw.log | grep BLOCK | tail -n 10 | grep -q "$(date '+%b %d')"; then
    echo "WARNING: Recent UFW blocks of K3s traffic detected"
    exit 1
fi

echo "OK: K3s firewall configuration healthy"
exit 0
```

## Reference Information

### K3s Default Network Configuration

- **Pod CIDR**: `10.42.0.0/16`
- **Service CIDR**: `10.43.0.0/16`
- **Flannel backend**: `vxlan`
- **VXLAN port**: `8472/udp`
- **API server**: `6443/tcp`

### Required UFW Rules Summary

```bash
# Minimal rules for K3s with UFW
ufw allow ssh
ufw allow 6443/tcp comment "K3s API"
ufw allow 8472/udp comment "Flannel VXLAN"  # CRITICAL
ufw allow 10250/tcp comment "kubelet API"
ufw allow from 10.42.0.0/16 comment "K3s pods"
ufw allow from 10.43.0.0/16 comment "K3s services"

# Control plane only
ufw allow 2379:2380/tcp comment "etcd"

# If using NodePort services
ufw allow 30000:32767/tcp comment "NodePort"
```

### External Resources

- [K3s Network Requirements](https://docs.k3s.io/installation/requirements#networking)
- [Flannel VXLAN Backend](https://github.com/flannel-io/flannel/blob/master/Documentation/backends.md#vxlan)
- [UFW Advanced Configuration](https://help.ubuntu.com/community/UFW)
- [Kubernetes Network Troubleshooting](https://kubernetes.io/docs/tasks/debug/debug-cluster/debug-service/)

---

**Note**: This guide addresses the tension between K3s's "no firewall" recommendation and security best practices. Always test thoroughly in non-production environments before applying firewall rules to production clusters.
