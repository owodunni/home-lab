# Homepage Dashboard

Application dashboard with Kubernetes auto-discovery for the homelab cluster.

## Security Architecture

Homepage runs in a **dedicated `homepage` namespace** isolated from other applications because it requires elevated permissions:

- **ClusterRole** with `get`, `list`, `watch` on Ingresses, Pods, Nodes across all namespaces
- **Metrics API access** to display cluster CPU/memory usage

This isolation prevents Homepage's broad permissions from affecting the `applications` namespace NetworkPolicy.

### NetworkPolicy

The included NetworkPolicy allows only:

| Direction | Target | Ports | Purpose |
|-----------|--------|-------|---------|
| Ingress | kube-system (Traefik) | 3000 | Web traffic |
| Egress | kube-system | 53 | DNS resolution |
| Egress | 10.43.0.0/16 | 443 | ClusterIP services |
| Egress | 192.168.1.0/24 | 6443 | Kubernetes API (control plane) |
| Egress | applications | 80, 443 | Service discovery |
| Egress | monitoring | 80, 443, 9090 | Prometheus metrics |
| Egress | longhorn-system | 9500 | Storage metrics |

## Features

- **Auto-discovery**: Discovers services from Ingress annotations
- **Cluster monitoring**: Real-time CPU/memory via metrics-server
- **Node monitoring**: Per-node resource breakdown

## Dependencies

- Traefik ingress controller
- cert-manager (TLS certificates)
- metrics-server (K3s built-in)

## Deployment

```bash
# Deploy (creates homepage namespace)
make app-deploy APP=homepage

# Check status
kubectl get pods -n homepage
kubectl logs -n homepage -l app.kubernetes.io/name=homepage
```

## Access

- **URL**: https://home.jardoole.xyz

## Adding Services to Dashboard

Add annotations to any app's Ingress:

```yaml
annotations:
  gethomepage.dev/enabled: "true"
  gethomepage.dev/name: "App Name"
  gethomepage.dev/group: "Media"  # or Monitoring, Admin
  gethomepage.dev/icon: "app-name.png"
  gethomepage.dev/description: "Brief description"
```

## Troubleshooting

**Services not appearing:**
```bash
kubectl auth can-i list ingresses --as=system:serviceaccount:homepage:homepage -A
kubectl logs -n homepage -l app.kubernetes.io/name=homepage
```

**API connection errors:**
```bash
kubectl exec -n homepage deploy/homepage -- sh -c \
  'wget -qO- --no-check-certificate https://10.43.0.1:443/api 2>&1'
```

**Metrics not showing:**
```bash
kubectl top nodes  # Verify metrics-server works
```

## Migration from applications namespace

If migrating from `applications` namespace:

```bash
# Delete old resources
kubectl delete deployment,service,ingress,configmap -n applications -l app.kubernetes.io/name=homepage
kubectl delete clusterrolebinding homepage
kubectl delete clusterrole homepage
kubectl delete serviceaccount homepage -n applications

# Deploy to new namespace
make app-deploy APP=homepage
```

## References

- [Homepage Documentation](https://gethomepage.dev/)
- [Kubernetes Installation](https://gethomepage.dev/installation/k8s/)
