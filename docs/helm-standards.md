# Helm Chart Standards

Standards and conventions for organizing Helm values files in the home-lab repository.

## File Organization

### Directory Structure

```
apps/<app-name>/
├── Chart.yml          # Chart metadata (YAML, not yaml)
├── values.yml         # Primary Helm values
├── values-prod.yml    # (Optional) Production overrides
├── values-dev.yml     # (Optional) Development overrides
└── secrets.yml        # (Optional) Encrypted vault values
```

### Naming Conventions

- **Chart metadata**: Always `Chart.yml` (capital C)
- **Values files**: `values.yml`, `values-<environment>.yml`
- **App playbooks**: `app.yml`
- **Prerequisites**: `prerequisites.yml`
- Use `.yml` extension (not `.yaml`) for consistency

## Chart.yml Format

Chart metadata defines the Helm chart to deploy:

```yaml
---
# Required fields
chart_repository: prometheus-community  # Helm repo name
chart_name: kube-prometheus-stack       # Chart name
chart_version: 67.4.0                   # Exact version (no ranges)
release_name: prometheus                # Helm release name
namespace: monitoring                   # Target namespace

# Optional fields
description: "Monitoring stack with Prometheus and Grafana"
create_namespace: true                  # Default: true
wait_for_ready: true                    # Default: true
upgrade_mode: false                     # Set via CLI for upgrades
```

### Version Pinning

**Always pin exact versions** - no version ranges:

```yaml
# Good
chart_version: 1.13.2

# Bad
chart_version: "~1.13.0"  # Tilde ranges
chart_version: "^1.13.0"  # Caret ranges
chart_version: latest     # Never use latest
```

## values.yml Format

### File Structure

Organize values files with clear sections:

```yaml
---
# 1. Resource limits (use common templates)
<<: *common-resource-limits-medium

# 2. Replication and scaling
replicaCount: 1

# 3. Node selection and tolerations
nodeSelector:
  kubernetes.io/os: linux

# 4. Storage configuration (apps on beelink use hostPath)
persistence:
  enabled: true
  type: hostPath
  hostPath: /mnt/storage/k8s-apps/<app-name>

# 5. Network configuration
service:
  type: ClusterIP
  port: 80

ingress:
  enabled: true
  # ...

# 6. Application-specific settings
# Group related settings together
monitoring:
  enabled: true
  serviceMonitor:
    enabled: true

# 7. Security settings
podSecurityContext:
  fsGroup: 1000

# 8. Secrets (vault references)
adminPassword: "{{ vault_app_admin_password }}"
```

### Comments

Add comments for non-obvious settings:

```yaml
# Good
storageOverProvisioningPercentage: 200  # Allow 2x thin provisioning

# Bad
storageOverProvisioningPercentage: 200  # Storage over-provisioning percentage
```

## Resource Limits

### Using Common Templates

Reference shared resource limit templates:

```yaml
# Small profile (single-instance apps, sidecars)
<<: *common-resource-limits-small
# Provides: 50m CPU / 64Mi RAM

# Medium profile (standard apps)
<<: *common-resource-limits-medium
# Provides: 100m CPU / 128Mi RAM

# Large profile (resource-intensive apps)
<<: *common-resource-limits-large
# Provides: 200m CPU / 256Mi RAM
```

### Custom Resource Limits

When common templates don't fit:

```yaml
resources:
  requests:
    cpu: 100m          # Guaranteed minimum
    memory: 128Mi
  limits:
    cpu: 200m          # Hard cap
    memory: 256Mi
```

### Pi CM5 Hardware Constraints

The cluster runs on Raspberry Pi CM5 modules with **4GB RAM**. Resource limits are critical:

- **Total cluster memory**: ~12GB (3x control plane + 1x worker)
- **System overhead**: ~4GB reserved for K3s, system processes
- **Available for apps**: ~8GB across all apps
- **Per-app guideline**: Most apps should use ≤512Mi RAM

**Always specify both requests and limits** to satisfy ResourceQuota.

## Node Selection

### Standard Node Selectors

Use consistent node selectors:

```yaml
# Linux nodes only (standard)
nodeSelector:
  kubernetes.io/os: linux

# Specific node (for testing)
nodeSelector:
  kubernetes.io/hostname: beelink

# Storage node (apps requiring local storage)
nodeSelector:
  node-role.kubernetes.io/storage: "true"
```

### Tolerations

Add tolerations when apps must run on tainted nodes:

```yaml
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

## Storage Configuration

### Using hostPath (Media Apps on Beelink)

Apps running on beelink use hostPath for direct storage access:

```yaml
persistence:
  config:
    enabled: true
    type: hostPath
    hostPath: /mnt/storage/k8s-apps/<app-name>
    globalMounts:
      - path: /config
```

### Using NFS (Apps on Control Plane)

Apps running on control plane nodes use NFS storage class:

```yaml
persistence:
  enabled: true
  storageClassName: nfs
  accessMode: ReadWriteOnce
  size: 10Gi
```

### Access Modes

- **ReadWriteOnce** (RWO): Single pod write access - default for most apps
- **ReadWriteMany** (RWX): Multiple pods write access - NFS supports this

## Ingress Configuration

### Standard HTTPS Ingress

Pattern for public HTTPS access with Let's Encrypt:

```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    # Force HTTPS
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    # Auto-provision Let's Encrypt certificate
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: app.jardoole.xyz
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: app-tls-secret  # cert-manager creates this
      hosts:
        - app.jardoole.xyz
```

### Ingress Naming

- **secretName pattern**: `<app-name>-tls-secret`
- **Host pattern**: `<app-name>.jardoole.xyz`
- **Certificate pattern**: cert-manager auto-creates `<secretName>` Certificate

## Security Context

### Pod Security Context

Set filesystem group for volume permissions:

```yaml
podSecurityContext:
  fsGroup: 1000                    # Group ID for volume access
  fsGroupChangePolicy: OnRootMismatch  # Performance optimization
```

### Container Security Context

Drop unnecessary capabilities:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault
```

## Secrets Management

### Vault Variables

All secrets use the `vault_` prefix and are stored in encrypted `group_vars/all/vault.yml`:

```yaml
# In values.yml (plaintext)
adminPassword: "{{ vault_grafana_admin_password }}"
apiToken: "{{ vault_cloudflare_api_token }}"

# In group_vars/all/vault.yml (encrypted with ansible-vault)
vault_grafana_admin_password: "actual-secret-value"
vault_cloudflare_api_token: "actual-token-value"
```

### Never Commit Plaintext Secrets

```yaml
# Bad - plaintext secret in values
adminPassword: "super-secret-password"

# Good - reference to vault variable
adminPassword: "{{ vault_app_admin_password }}"
```

## Sub-Chart Configuration

For charts with dependencies (sub-charts):

```yaml
# Parent chart config
parentSetting: value

# Sub-chart config (use chart name as key)
grafana:
  enabled: true
  persistence:
    enabled: true
    size: 5Gi

prometheus:
  enabled: true
  retention: 15d
```

### Sub-Chart Resource Limits

Apply resource limits at the correct level:

```yaml
# Wrong - applies to parent chart only
resources:
  limits:
    cpu: 100m

# Correct - applies to sub-chart
grafana:
  resources:
    limits:
      cpu: 100m
```

### Sub-Chart Sidecar Resources

For charts with sidecars, check the chart's values.yaml for the correct path:

```yaml
# Grafana example - shared resources for all sidecars
grafana:
  sidecar:
    resources:  # Applies to all sidecars
      limits:
        cpu: 100m
        memory: 128Mi
```

## Values File Validation

### Pre-Deployment Checks

Always validate before deploying:

```bash
# Lint values file
make helm-lint

# Validate rendered manifests
make helm-validate

# Dry-run deployment
make app-deploy APP=<name> --check
```

### Common Validation Errors

**Syntax errors:**
```yaml
# Bad - invalid YAML
key: value
  nested: wrong-indent

# Good
key: value
nested:
  correct: indent
```

**Type mismatches:**
```yaml
# Bad - string where int expected
replicaCount: "1"

# Good
replicaCount: 1
```

**Missing quotes for special values:**
```yaml
# Bad - YAML interprets as boolean
value: true

# Good - force string interpretation when needed
value: "true"
```

## Helm Diff

Use helm-diff to preview changes before applying:

```bash
# Show what will change
helm diff upgrade <release-name> <chart> -f values.yml

# Integration in playbook (automatic with deploy-helm-app.yml)
```

## Best Practices Summary

1. **Pin versions** - Use exact chart versions, not ranges
2. **Use common templates** - Reference `common-resource-limits-*` for resources
3. **Document non-obvious settings** - Add comments explaining why
4. **Organize logically** - Follow the standard section order
5. **Validate early** - Lint and validate before deployment
6. **Keep values DRY** - Use YAML anchors and common templates
7. **Namespace secrets** - All secrets use `vault_` prefix
8. **Test incrementally** - Deploy to dev namespace first when possible

## See Also

- [App Deployment Guide](app-deployment-guide.md) - Complete deployment workflow
- [Project Structure](project-structure.md) - Repository organization
- [Ansible Vault Usage](../CLAUDE.md#ansible-vault-usage) - Secret management
