# Node Feature Discovery (NFD)

Automatically detects hardware features and labels Kubernetes nodes. Required for Intel GPU Device Plugin to identify nodes with Intel GPUs.

## Purpose

NFD runs as a DaemonSet on all nodes and:
- Detects CPU, PCI, USB, and kernel features
- Labels nodes with discovered hardware capabilities
- Enables device plugins to schedule workloads on appropriate nodes

## Dependencies

None - this is a cluster infrastructure component

## Deployment

```bash
make app-deploy APP=node-feature-discovery
```

## Verification

Check that nodes are labeled with detected features:

```bash
# Check for CPU vendor ID
kubectl get nodes -L feature.node.kubernetes.io/cpu-model.vendor_id

# Check for PCI devices (Intel GPU should appear)
kubectl get nodes -o json | jq '.items[].metadata.labels' | grep pci

# Check NFD pods running
kubectl get pods -n node-feature-discovery
```

Expected labels on beelink node:
- `feature.node.kubernetes.io/cpu-model.vendor_id: Intel`
- `feature.node.kubernetes.io/pci-0300_8086.present: true` (Intel GPU)

## Configuration

The default configuration detects:
- **CPU**: Model, vendor, instruction sets
- **PCI**: Graphics cards (class 0300), display controllers (class 0380)
- **Kernel**: Config options and loaded modules
- **USB**: Connected devices

## Learn More

- [Official Documentation](https://kubernetes-sigs.github.io/node-feature-discovery/)
- [Intel GPU Blog](https://blog.stonegarden.dev/articles/2024/05/intel-quick-sync-k8s/)
