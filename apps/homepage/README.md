# Homepage Dashboard

Modern application dashboard with Kubernetes auto-discovery and cluster monitoring.

## Features

- **Auto-discovery**: Automatically discovers services from Ingress annotations
- **Cluster monitoring**: Real-time CPU/memory metrics via metrics-server
- **Node monitoring**: Per-node CPU and memory usage
- **Service widgets**: Optional API integration with Radarr, Sonarr, Jellyfin, etc.

## Resource Monitoring

Homepage displays:
- **Cluster CPU/Memory**: Aggregate cluster resource usage
- **Node CPU/Memory**: Per-node resource breakdown

**Disk Space Monitoring**: Homepage's Kubernetes widget does not include disk metrics. For root filesystem monitoring:
- Use **Grafana** dashboard at https://grafana.jardoole.xyz
- Node Exporter metrics collected by Prometheus
- Check the "Node Exporter / Nodes" dashboard for detailed disk usage

## Dependencies

- Traefik ingress controller
- cert-manager (for TLS certificates)
- metrics-server (for cluster metrics - already installed)

## Deployment

Homepage is deployed using raw Kubernetes manifests (not Helm):

```bash
# Deploy or upgrade
make app-deploy APP=homepage

# Check status
kubectl get pods -n applications -l app.kubernetes.io/name=homepage
kubectl logs -n applications -l app.kubernetes.io/name=homepage

# Manual deployment
kubectl apply -f apps/homepage/manifests.yml
```

## Access

- **URL**: https://home.jardoole.xyz
- **Authentication**: None (network-protected)

## Configuration

All configuration is in `manifests.yml`:
- **RBAC**: ClusterRole with read-only permissions
- **kubernetes.yaml**: `mode: cluster` for auto-discovery
- **settings.yaml**: Title, layout, and groups
- **widgets.yaml**: Cluster and node monitoring widgets

To update configuration:
1. Edit `apps/homepage/manifests.yml`
2. Run `make app-deploy APP=homepage`

## Adding Services to Dashboard

Services are automatically discovered via Ingress annotations:

```yaml
annotations:
  gethomepage.dev/enabled: "true"
  gethomepage.dev/name: "App Name"
  gethomepage.dev/description: "Brief description"
  gethomepage.dev/group: "Media"  # Categories: Media, Monitoring, Admin
  gethomepage.dev/icon: "app-icon.png"
```

**Example for Radarr** (`apps/radarr/values.yml`):

```yaml
ingress:
  app:
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
      cert-manager.io/cluster-issuer: letsencrypt-prod
      # Homepage auto-discovery
      gethomepage.dev/enabled: "true"
      gethomepage.dev/name: "Radarr"
      gethomepage.dev/description: "Movie Collection Manager"
      gethomepage.dev/group: "Media"
      gethomepage.dev/icon: "radarr.png"
```

After updating annotations, redeploy the app:
```bash
make app-deploy APP=radarr
```

## Troubleshooting

**Services not appearing:**
1. Check Ingress annotations: `kubectl get ingress -n media radarr -o yaml`
2. Verify RBAC permissions: `kubectl auth can-i list ingresses --as=system:serviceaccount:applications:homepage -A`
3. Check Homepage logs: `kubectl logs -n applications -l app.kubernetes.io/name=homepage`

**API Errors:**
1. Verify ServiceAccount token mounted: `kubectl exec -n applications deploy/homepage -- ls /var/run/secrets/kubernetes.io/serviceaccount/`
2. Test API access: `kubectl exec -n applications deploy/homepage -- wget -O- http://localhost:3000/api/services`

**Metrics not showing:**
- Verify metrics-server: `kubectl top nodes`
- Check widgets.yaml in `manifests.yml`

## Architecture

**Deployment Method**: Raw Kubernetes manifests (not Helm)
- Simpler configuration management
- Direct control over all resources
- Follows official Homepage documentation pattern

**Resources Created**:
- Namespace: `applications`
- ServiceAccount with RBAC (ClusterRole + ClusterRoleBinding)
- 5 ConfigMaps (kubernetes, settings, widgets, services, bookmarks)
- Deployment (1 replica, 100m CPU / 128Mi RAM)
- Service (ClusterIP)
- Ingress (Traefik with Let's Encrypt TLS)

## References

- [Homepage Documentation](https://gethomepage.dev/)
- [Kubernetes Installation](https://gethomepage.dev/installation/k8s/)
- [Kubernetes Configuration](https://gethomepage.dev/configs/kubernetes/)
- [Service Widgets](https://gethomepage.dev/configs/service-widget/)
