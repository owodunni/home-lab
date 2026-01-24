## kube-prometheus-stack

Comprehensive monitoring solution for Kubernetes with Prometheus, Grafana, and Alertmanager.

## Overview

The kube-prometheus-stack provides a complete monitoring platform:
- **Prometheus**: Metrics collection and time-series database
- **Grafana**: Visualization and dashboarding
- **Alertmanager**: Alert routing and notification management
- **Prometheus Operator**: Manages Prometheus instances via CRDs
- **kube-state-metrics**: Exposes Kubernetes object metrics
- **prometheus-node-exporter**: Exposes node hardware and OS metrics

## Dependencies

- **hostPath storage (on beelink) (metrics data, Grafana dashboards)
- **cert-manager**: For TLS certificates (HTTPS access)
- **Traefik**: For ingress routing
- **vault_grafana_admin_password**: Vault variable for Grafana admin password

## Configuration

### Prometheus
- **Storage**: 10Gi NFS persistent volume
- **Retention**: Default 15 days
- **Resource limits**: 200m-500m CPU, 512Mi-1Gi memory
- **Scrape interval**: Default 30s
- **HTTPS access**: https://prometheus.jardoole.xyz

### Grafana
- **Storage**: 5Gi NFS persistent volume
- **Resource limits**: 100m-200m CPU, 128Mi-256Mi memory
- **Admin password**: From vault (vault_grafana_admin_password)
- **Sidecar**: Auto-loads dashboards and datasources from ConfigMaps
- **HTTPS access**: https://grafana.jardoole.xyz

### Alertmanager
- **Storage**: 5Gi NFS persistent volume
- **Resource limits**: 100m-200m CPU, 128Mi-256Mi memory
- **Configuration**: Default alert routing (customize via AlertmanagerConfig CRDs)

### Additional Components
- **Prometheus Operator**: 100m-200m CPU, 128Mi-256Mi memory
- **kube-state-metrics**: 50m-100m CPU, 64Mi-128Mi memory
- **prometheus-node-exporter**: 50m-100m CPU, 64Mi-128Mi memory (runs on all nodes)

## Deployment

Deploy via orchestration playbook (recommended for cluster setup):
```bash
make k3s-monitoring
```

Or deploy standalone:
```bash
make app-deploy APP=kube-prometheus-stack
```

**Note**: Requires vault_grafana_admin_password to be defined in group_vars/all/vault.yml.

## Access

### Prometheus UI
**URL**: https://prometheus.jardoole.xyz

Features:
- Query metrics using PromQL
- View targets and service discovery
- Check alerting rules
- Browse time-series data

### Grafana
**URL**: https://grafana.jardoole.xyz
**Default login**: admin / [vault_grafana_admin_password]

Features:
- Pre-installed Kubernetes dashboards
- Prometheus datasource auto-configured
- Create custom dashboards
- Set up alerts and notifications

### Alertmanager
**URL**: https://prometheus.jardoole.xyz/alertmanager

Features:
- View active alerts
- Manage alert silences
- Configure notification receivers

## Monitoring Features

### Built-in Dashboards
Grafana comes with pre-configured dashboards for:
- Kubernetes cluster overview
- Node metrics (CPU, memory, disk, network)
- Pod resource usage
- Persistent volume monitoring
- API server metrics
- etcd metrics
- CoreDNS metrics

### Metrics Collection
Prometheus automatically scrapes:
- Kubernetes API server
- kubelet (node metrics)
- cAdvisor (container metrics)
- kube-state-metrics (K8s object state)
- Node exporter (hardware/OS metrics)
- Custom ServiceMonitor/PodMonitor resources

### ServiceMonitor/PodMonitor
Create custom metric collection for your apps:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: applications
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
    - port: metrics
      interval: 30s
```

## Maintenance

### Upgrade Stack
1. Check [release notes](https://github.com/prometheus-community/helm-charts/releases)
2. Update `chart_version` in Chart.yml
3. Redeploy: `make app-deploy APP=kube-prometheus-stack`

### Grafana Password Reset
If you need to reset the Grafana admin password:
```bash
# Update vault_grafana_admin_password in group_vars/all/vault.yml
uv run ansible-vault edit group_vars/all/vault.yml

# Redeploy to apply new password
make app-deploy APP=kube-prometheus-stack
```

### Storage Management
Check persistent volume usage:
```bash
# Prometheus data
kubectl get pvc -n monitoring -l app.kubernetes.io/name=prometheus

# Grafana data
kubectl get pvc -n monitoring -l app.kubernetes.io/name=grafana

# Alertmanager data
kubectl get pvc -n monitoring -l app.kubernetes.io/name=alertmanager
```

Increase storage if needed (update values.yml):
```yaml
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 20Gi  # Increased from 10Gi
```

## Troubleshooting

### Prometheus Not Scraping Targets
Check ServiceMonitor/PodMonitor resources:
```bash
kubectl get servicemonitor --all-namespaces
kubectl get podmonitor --all-namespaces
```

Check Prometheus logs:
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus -c prometheus
```

View scrape targets in Prometheus UI:
https://prometheus.jardoole.xyz/targets

### Grafana Datasources Not Loading (Fresh Install)

After a fresh install or PVC wipe, Grafana dashboards may show "No data" errors because
the Prometheus datasource isn't loaded. This is a race condition: the sidecar writes the
datasource config after Grafana has already finished provisioning, and `REQ_SKIP_INIT=true`
prevents the initial reload.

**Symptoms:**
- Dashboards show "No data" or datasource errors
- `/api/datasources` returns empty array `[]`

**Quick fix** - trigger manual reload:
```bash
# Get admin password
PASS=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d)

# Trigger datasource reload
kubectl exec -n monitoring deploy/prometheus-grafana -c grafana -- \
  wget -q -O- --header="Authorization: Basic $(echo -n admin:$PASS | base64)" \
  --post-data="" "http://localhost:3000/api/admin/provisioning/datasources/reload"
```

**Why this happens:**
- Datasources are persisted in Grafana's SQLite database after first load
- Wiping the PVC deletes this database, requiring re-provisioning
- The sidecar's `REQ_SKIP_INIT=true` prevents reload on initial sync

### Grafana Not Loading Dashboards
Check sidecar logs:
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -c grafana-sc-datasources
```

Verify ConfigMaps with dashboards:
```bash
kubectl get configmap -n monitoring -l grafana_dashboard=1
```

### Certificate Issues
Check certificate status:
```bash
kubectl get certificate -n monitoring
kubectl describe certificate prometheus-tls-secret -n monitoring
kubectl describe certificate grafana-tls-secret -n monitoring
```

### High Resource Usage
Monitor resource consumption:
```bash
# Check Prometheus memory usage
kubectl top pod -n monitoring -l app.kubernetes.io/name=prometheus

# Check Grafana resource usage
kubectl top pod -n monitoring -l app.kubernetes.io/name=grafana
```

Adjust resource limits in values.yml if needed.

### Alertmanager Not Sending Alerts
Check Alertmanager configuration:
```bash
kubectl get secret -n monitoring alertmanager-prometheus-kube-prometheus-alertmanager -o yaml
```

View Alertmanager logs:
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager
```

## Custom Alerts

Create PrometheusRule resources for custom alerts:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-app-alerts
  namespace: applications
  labels:
    prometheus: kube-prometheus
spec:
  groups:
    - name: my-app
      interval: 30s
      rules:
        - alert: MyAppDown
          expr: up{job="my-app"} == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "My App is down"
            description: "My App has been down for more than 5 minutes"
```

## References

- [kube-prometheus-stack Documentation](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Alertmanager Documentation](https://prometheus.io/docs/alerting/latest/alertmanager/)
- [Prometheus Operator](https://prometheus-operator.dev/)
