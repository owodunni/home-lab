# K3s Cluster Maintenance Guide

## Quick Reference Commands

### Cluster Status
```bash
# Check cluster health
make k3s-cluster-check

# View all nodes
ansible pi-cm5-1 -m shell -a "sudo kubectl get nodes -o wide --kubeconfig /etc/rancher/k3s/k3s.yaml"

# Check system pods
ansible pi-cm5-1 -m shell -a "sudo kubectl get pods -A --kubeconfig /etc/rancher/k3s/k3s.yaml"

# Service status on all nodes
ansible control_plane -m shell -a "systemctl is-active k3s"
```

### Logs and Troubleshooting
```bash
# Recent logs from all nodes
ansible control_plane -m shell -a "journalctl -u k3s --since='1 hour ago' --no-pager -l | tail -20"

# Detailed logs from specific node
ansible pi-cm5-1 -m shell -a "cat /var/log/k3s.log | tail -50"

# Check etcd health
ansible pi-cm5-1 -m shell -a "sudo kubectl get endpoints kube-scheduler -n kube-system --kubeconfig /etc/rancher/k3s/k3s.yaml"
```

## Common Operations

### Complete Redeployment
```bash
# Full cluster rebuild (for testing/recovery)
make k3s-uninstall
make k3s-cluster
```

### Single Node Restart
```bash
# Restart K3s service on specific node
ansible pi-cm5-1 -m systemd -a "name=k3s state=restarted" --become

# Wait for node to rejoin cluster
ansible pi-cm5-1 -m shell -a "sudo kubectl get nodes --kubeconfig /etc/rancher/k3s/k3s.yaml"
```

### Configuration Changes
1. Edit configuration files in `group_vars/k3s_cluster/k3s.yml` or `host_vars/`
2. Run `make k3s-cluster-check` to validate changes
3. Apply with `make k3s-cluster`

## Monitoring

### Health Checks
```bash
# Cluster info
ansible pi-cm5-1 -m shell -a "sudo kubectl cluster-info --kubeconfig /etc/rancher/k3s/k3s.yaml"

# Resource usage
ansible control_plane -m shell -a "free -h && df -h /"

# Network connectivity
ansible control_plane -m ping
```

### Key Metrics to Monitor
- **Node Status**: All nodes should show `Ready`
- **System Pods**: CoreDNS, metrics-server, local-path-provisioner should be `Running`
- **etcd Health**: Check logs for consensus/leader election issues
- **Disk Space**: Monitor `/var/lib/rancher/k3s` usage
- **Memory**: K3s typically uses 200-400MB per node

## Backup and Recovery

### Important Files to Backup
```bash
# Cluster configuration
/etc/rancher/k3s/k3s.yaml

# etcd data (on each node)
/var/lib/rancher/k3s/server/db/etcd/

# Cluster token
/var/lib/rancher/k3s/server/token

# Ansible configuration
group_vars/k3s_cluster/k3s.yml
host_vars/pi-cm5-*.yml
```

### Recovery Scenarios

**Single Node Failure**:
1. Replace/repair failed hardware
2. Run `make k3s-cluster` (role will detect and reconfigure)
3. Node will automatically rejoin cluster

**Complete Cluster Loss**:
1. Restore from backup or redeploy fresh
2. Run `make k3s-cluster`
3. Restore application data from backups

**etcd Corruption**:
1. Stop K3s on all nodes: `ansible control_plane -m systemd -a "name=k3s state=stopped" --become`
2. Remove corrupt etcd data: `rm -rf /var/lib/rancher/k3s/server/db/etcd/`
3. Redeploy: `make k3s-uninstall && make k3s-cluster`

## Upgrades

### K3s Version Updates
1. Update `k3s_release_version` in `group_vars/k3s_cluster/k3s.yml`
2. Test upgrade on single node first: `ansible-playbook playbooks/k3s-cluster.yml --limit pi-cm5-1`
3. If successful, upgrade all nodes: `make k3s-cluster`

### System Updates
- **Automatic**: Unattended upgrades run at staggered times (02:00, 02:30, 03:00)
- **Manual**: Run `make upgrade` for immediate OS updates

## Troubleshooting

### Common Issues

**Node Not Joining Cluster**:
```bash
# Check connectivity to first node
ansible pi-cm5-2 -m shell -a "nc -zv 192.168.92.24 6443"

# Verify cluster token
ansible control_plane -m shell -a "cat /var/lib/rancher/k3s/server/token"

# Check etcd logs
ansible pi-cm5-1 -m shell -a "journalctl -u k3s | grep etcd"
```

**API Server Not Responding**:
```bash
# Check if port is listening
ansible pi-cm5-1 -m shell -a "ss -tlnp | grep :6443"

# Check for certificate issues
ansible pi-cm5-1 -m shell -a "sudo kubectl cluster-info --kubeconfig /etc/rancher/k3s/k3s.yaml"
```

**High Memory Usage**:
```bash
# Check pod resource usage
ansible pi-cm5-1 -m shell -a "sudo kubectl top nodes --kubeconfig /etc/rancher/k3s/k3s.yaml"
```

**etcd Issues**:
```bash
# Check etcd member list
ansible pi-cm5-1 -m shell -a "sudo /usr/local/bin/k3s etcd-snapshot ls"

# etcd cluster health
ansible control_plane -m shell -a "journalctl -u k3s | grep 'became leader'"
```

### Log Analysis
```bash
# Look for common error patterns
ansible control_plane -m shell -a "journalctl -u k3s | grep -i error | tail -10"

# Check for etcd election issues
ansible control_plane -m shell -a "journalctl -u k3s | grep -i 'election\|leader'"

# Network connectivity issues
ansible control_plane -m shell -a "journalctl -u k3s | grep -i 'connection refused\|timeout'"
```

## Performance Tuning

### Resource Limits (Already Configured)
```yaml
# In k3s.yml - already applied
kubelet-arg:
  - "max-pods=50"                    # Conservative for Pi hardware
  - "image-gc-high-threshold=80"     # Aggressive cleanup
  - "eviction-hard=memory.available<256Mi"  # Memory protection
```

### Monitoring Resource Usage
```bash
# Node resources
ansible control_plane -m shell -a "top -bn1 | grep -E '(k3s|containerd)'"

# Disk space trends
ansible control_plane -m shell -a "du -sh /var/lib/rancher/k3s/"
```

## Security

### Cluster Token Rotation
```bash
# Generate new token
NEW_TOKEN=$(openssl rand -hex 32)

# Update configuration
sed -i "s/homelab-k3s-cluster-token-change-this/$NEW_TOKEN/" group_vars/k3s_cluster/k3s.yml

# Redeploy cluster
make k3s-uninstall && make k3s-cluster
```

### Certificate Management
- **Auto-renewal**: K3s handles certificate rotation automatically
- **Manual check**: Certificates located in `/var/lib/rancher/k3s/server/tls/`

## Emergency Procedures

### Emergency Shutdown
```bash
# Graceful shutdown all nodes
ansible control_plane -m systemd -a "name=k3s state=stopped" --become
ansible control_plane -m shell -a "shutdown -h now" --become
```

### Emergency Access
```bash
# Direct kubectl access from any node
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes

# Emergency cluster reset (DESTRUCTIVE)
make k3s-uninstall  # Removes all cluster data
```

### Split-Brain Recovery
If etcd cluster splits:
1. Identify healthy node with latest data
2. Stop K3s on all nodes
3. Start fresh with healthy node as init node
4. Allow other nodes to rejoin

---

**Maintenance Schedule**:
- **Daily**: Automated health checks
- **Weekly**: Manual cluster status review
- **Monthly**: Review logs and resource usage
- **Quarterly**: Backup verification and DR testing

**Emergency Contacts**: Document team contacts for cluster emergencies
**Escalation Path**: Define when to engage additional support
