# Kubernetes Applications

This directory contains standardized Helm chart deployments for the K3s cluster.

## Quick Start

```bash
# List available apps
ls apps/

# Validate Helm values
make helm-lint

# Deploy an app
make app-deploy APP=<app-name>

# Check app status
make app-status APP=<app-name>

# List all deployed apps
make app-list
```

## Directory Structure

```
apps/
├── README.md                 # This file
├── _common/                  # Shared components
│   ├── values/               # Reusable Helm value templates
│   │   └── resource-limits.yml
│   └── tasks/                # Reusable Ansible tasks
│       ├── validate-chart.yml
│       └── wait-for-ready.yml
└── <app-name>/               # Individual app directory
    ├── Chart.yml             # Helm chart metadata
    ├── values.yml            # Helm values configuration
    ├── app.yml               # Deployment playbook
    ├── prerequisites.yml     # (Optional) Pre-deployment tasks
    └── README.md             # App-specific documentation
```

## Creating a New App

See the complete guide: [App Deployment Guide](../docs/app-deployment-guide.md)

Quick version:

1. Create directory: `mkdir -p apps/my-app`
2. Create `Chart.yml` with chart metadata
3. Create `values.yml` with Helm configuration
4. Create `app.yml` that calls `playbooks/deploy-helm-app.yml`
5. Validate: `make helm-lint`
6. Deploy: `make app-deploy APP=my-app`

## Common Components

### Resource Limits (`_common/values/resource-limits.yml`)

Provides YAML anchors for Pi CM5-optimized resource limits:

- `*common-resource-limits-small` - 50m CPU, 64Mi RAM
- `*common-resource-limits-medium` - 100m CPU, 128Mi RAM
- `*common-resource-limits-large` - 200m CPU, 256Mi RAM

Usage in `values.yml`:
```yaml
---
<<: *common-resource-limits-medium

# Your app configuration
```

### Validation Tasks (`_common/tasks/validate-chart.yml`)

Automatically validates Helm charts before deployment:
- Helm lint with strict mode
- Template rendering validation
- Manifest schema validation

### Readiness Checks (`_common/tasks/wait-for-ready.yml`)

Waits for deployments/statefulsets to reach ready state after deployment.

## Standards

All apps must follow:

1. **Exact version pinning** - No version ranges
2. **Resource limits** - All containers specify requests/limits
3. **Vault secrets** - Use `{{ vault_* }}` pattern
4. **HTTPS ingress** - cert-manager integration
5. **Documentation** - README.md for each app

See [Helm Standards](../docs/helm-standards.md) for complete conventions.

## Example Apps

- `test-app/` - Simple example demonstrating the pattern
- (More apps will be migrated to this structure)

## Makefile Commands

```bash
make helm-lint          # Lint all Helm values files
make helm-validate      # Validate rendered manifests
make app-deploy APP=x   # Deploy specific app
make app-upgrade APP=x  # Upgrade app with new values
make app-list           # List all deployed Helm releases
make app-status APP=x   # Show app deployment status
```

## Troubleshooting

**App won't deploy:**
1. Check Helm repo exists: `helm repo list`
2. Validate chart: `make helm-lint`
3. Check namespace: `kubectl get namespace`

**ResourceQuota errors:**
- Ensure all containers have resource limits
- Use common resource limit templates

**Certificate issues:**
- Verify ClusterIssuer: `kubectl get clusterissuer`
- Check certificate: `kubectl get certificate -n <namespace>`

See the [App Deployment Guide](../docs/app-deployment-guide.md) for detailed troubleshooting.
