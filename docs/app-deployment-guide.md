# App Deployment Guide

This guide explains how to deploy applications to the K3s cluster using the standardized app structure.

## Quick Start

Deploy an existing app:
```bash
# List available apps
ls apps/

# Deploy an app
make app-deploy APP=<app-name>

# Check deployment status
make app-status APP=<app-name>

# List all deployed apps
make app-list
```

## App Structure

Each app follows this standard structure:

```
apps/<app-name>/
├── Chart.yml           # Chart metadata (repo, name, version)
├── values.yml          # Helm values configuration
├── app.yml             # Playbook that calls reusable deployer
├── README.md           # App-specific documentation
└── prerequisites.yml   # (Optional) Pre-deployment tasks
```

### Chart.yml Example

```yaml
---
# Chart metadata for cert-manager
chart_repository: jetstack
chart_name: cert-manager
chart_version: v1.13.2
release_name: cert-manager
namespace: cert-manager
description: "Certificate management for Kubernetes with Let's Encrypt support"
```

### values.yml Example

```yaml
---
# Helm values for cert-manager
# Reference common values using anchors
<<: *common-resource-limits-small

installCRDs: true

replicaCount: 1

nodeSelector:
  kubernetes.io/os: linux
```

### app.yml Example

```yaml
---
# App deployment playbook
- name: Deploy cert-manager
  import_playbook: ../../playbooks/deploy-helm-app.yml
  vars:
    app_chart_file: "{{ playbook_dir }}/Chart.yml"
    app_values_file: "{{ playbook_dir }}/values.yml"
    prerequisites_playbook: "{{ playbook_dir }}/prerequisites.yml"
```

## Creating a New App

### Step 1: Create App Directory

```bash
mkdir -p apps/my-app
cd apps/my-app
```

### Step 2: Create Chart.yml

Define the Helm chart to deploy:

```yaml
---
chart_repository: bitnami  # Helm repo name (must be added to cluster)
chart_name: nginx          # Chart name from repository
chart_version: 15.1.0      # Specific chart version
release_name: my-app       # Helm release name
namespace: applications    # Kubernetes namespace
description: "My application description"
```

### Step 3: Create values.yml

Configure the Helm chart:

```yaml
---
# Use common resource limits for Pi CM5 hardware
<<: *common-resource-limits-medium

# App-specific configuration
replicaCount: 1

service:
  type: ClusterIP
  port: 80

ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: my-app.jardoole.xyz
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: my-app-tls
      hosts:
        - my-app.jardoole.xyz
```

### Step 4: Create app.yml

Simple wrapper playbook:

```yaml
---
- name: Deploy My App
  import_playbook: ../../playbooks/deploy-helm-app.yml
  vars:
    app_chart_file: "{{ playbook_dir }}/Chart.yml"
    app_values_file: "{{ playbook_dir }}/values.yml"
```

### Step 5: Create README.md

Document your app:

```markdown
# My App

Brief description of what this app does.

## Dependencies

- Longhorn (for persistent storage)
- cert-manager (for TLS certificates)

## Access

- URL: https://my-app.jardoole.xyz
- Default credentials: See vault secrets

## Maintenance

Update chart version in Chart.yml and redeploy.
```

### Step 6: Validate and Deploy

```bash
# Lint Helm values
make helm-lint

# Validate rendered manifests
make helm-validate

# Deploy
make app-deploy APP=my-app

# Check status
make app-status APP=my-app
```

## Common Patterns

### Using Resource Limit Templates

Reference common resource limits defined in `apps/_common/values/resource-limits.yml`:

```yaml
# Small: 50m CPU, 64Mi RAM
<<: *common-resource-limits-small

# Medium: 100m CPU, 128Mi RAM
<<: *common-resource-limits-medium

# Large: 200m CPU, 256Mi RAM
<<: *common-resource-limits-large
```

### Adding Prerequisites

Create `prerequisites.yml` for tasks that must run before deployment:

```yaml
---
- name: Install required packages
  ansible.builtin.package:
    name:
      - open-iscsi
      - nfs-common
    state: present

- name: Enable required services
  ansible.builtin.systemd:
    name: iscsid
    enabled: true
    state: started
```

Reference in `app.yml`:
```yaml
vars:
  prerequisites_playbook: "{{ playbook_dir }}/prerequisites.yml"
```

### Using Vault Secrets

Reference encrypted secrets in values:

```yaml
# In values.yml
adminPassword: "{{ vault_app_admin_password }}"
apiToken: "{{ vault_app_api_token }}"
```

Secrets must be defined in `group_vars/all/vault.yml` with `vault_` prefix.

### Ingress with TLS

Standard pattern for HTTPS access:

```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: app.jardoole.xyz
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: app-tls-secret
      hosts:
        - app.jardoole.xyz
```

### Persistent Storage

Use Longhorn for persistent volumes:

```yaml
persistence:
  enabled: true
  storageClass: longhorn
  size: 10Gi
  accessMode: ReadWriteOnce
```

## Troubleshooting

### App Won't Deploy

1. **Check Helm repository exists:**
   ```bash
   helm repo list
   ```

2. **Validate Chart.yml:**
   ```bash
   make helm-lint
   ```

3. **Check namespace exists:**
   ```bash
   kubectl get namespace <namespace>
   ```

4. **View deployment logs:**
   ```bash
   kubectl logs -n <namespace> -l app=<app-name>
   ```

### ResourceQuota Violations

Ensure all containers have resource limits defined:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 100m
    memory: 128Mi
```

### Certificate Issues

Check certificate status:
```bash
kubectl get certificate -n <namespace>
kubectl describe certificate <cert-name> -n <namespace>
```

Verify ClusterIssuer:
```bash
kubectl get clusterissuer
```

### Network Policy Blocking Traffic

Ensure namespace has correct labels:
```bash
kubectl label namespace <namespace> name=<namespace>
```

## Makefile Reference

```bash
make helm-lint           # Lint all Helm values files
make helm-validate       # Validate rendered manifests
make app-deploy APP=x    # Deploy specific app
make app-upgrade APP=x   # Upgrade specific app
make app-list            # List all deployed apps
make app-status APP=x    # Show app status
```

## See Also

- [Helm Standards](helm-standards.md) - Values file organization and conventions
- [Project Structure](project-structure.md) - Overall repository organization
- [Playbook Guidelines](playbook-guidelines.md) - Ansible best practices
