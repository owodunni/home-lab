# Intel GPU Device Plugin

Kubernetes device plugin that exposes Intel GPUs as schedulable resources (`gpu.intel.com/i915`). Enables hardware-accelerated transcoding in Jellyfin via Intel QuickSync.

## Purpose

The plugin:
- Advertises Intel GPU capabilities to Kubernetes scheduler
- Handles cgroup device whitelisting automatically
- Allows pods to request GPU access via resource limits
- Supports sharing GPU among multiple pods

## Dependencies

- **Node Feature Discovery (NFD)**: Must be installed first to label nodes with Intel GPU
- **Intel media drivers**: Installed on host via `make beelink-gpu-setup`

## Deployment

```bash
# Prerequisites
make app-deploy APP=node-feature-discovery

# Deploy Intel GPU plugin
make app-deploy APP=intel-gpu-plugin
```

## Verification

Check that plugin is running and advertising GPU resources:

```bash
# Check plugin pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=intel-device-plugins-gpu

# Verify GPU resources advertised on beelink node
kubectl describe node beelink | grep -A 5 "Capacity:" | grep gpu

# Expected output:
#   gpu.intel.com/i915:  1000m
```

## Using GPU in Pods

Add resource request to pod spec:

```yaml
resources:
  limits:
    gpu.intel.com/i915: 1000m  # Request GPU access
```

The plugin automatically:
- Mounts /dev/dri devices into container
- Configures cgroup device whitelists
- Sets appropriate group permissions

## Configuration

- **sharedDevNum: 10**: Allows up to 10 pods to share the GPU simultaneously
- **enableMonitoring: true**: Exposes metrics for GPU utilization
- **nodeSelector**: Only runs on nodes labeled by NFD as having Intel GPU

## Troubleshooting

### Plugin pod not starting

```bash
# Check NFD installed and node labeled
kubectl get nodes -L feature.node.kubernetes.io/pci-0300_8086.present

# If label missing, verify NFD running
kubectl get pods -n node-feature-discovery
```

### GPU resource not advertised

```bash
# Check plugin logs
kubectl logs -n kube-system -l app.kubernetes.io/name=intel-device-plugins-gpu

# Verify /dev/dri exists on host
ssh beelink "ls -l /dev/dri/"
```

### Pod can't access GPU

```bash
# Verify resource request in pod spec
kubectl get pod <POD> -o yaml | grep -A 2 "resources:"

# Check device mounted
kubectl exec <POD> -- ls -l /dev/dri/
```

## Learn More

- [Intel Device Plugins Documentation](https://intel.github.io/intel-device-plugins-for-kubernetes/)
- [Device Plugin Design](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
- [Intel QuickSync on K8s Blog](https://blog.stonegarden.dev/articles/2024/05/intel-quick-sync-k8s/)
