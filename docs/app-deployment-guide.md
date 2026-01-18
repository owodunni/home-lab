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
    app_chart_file: "{{ inventory_dir }}/apps/cert-manager/Chart.yml"
    app_values_file: "{{ inventory_dir }}/apps/cert-manager/values.yml"
    prerequisites_playbook: "{{ inventory_dir }}/apps/cert-manager/prerequisites.yml"
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
    app_chart_file: "{{ inventory_dir }}/apps/my-app/Chart.yml"
    app_values_file: "{{ inventory_dir }}/apps/my-app/values.yml"
```

### Step 5: Create README.md

Document your app:

```markdown
# My App

Brief description of what this app does.

## Dependencies

- NFS storage (persistent storage)
- cert-manager (for TLS certificates)

## Access

- URL: https://my-app.jardoole.xyz
- Default credentials: See vault secrets

## Maintenance

Update chart version in Chart.yml and redeploy.
```

### Step 6: Validate and Deploy

```bash
# Lint and validate Helm values and templates
make lint-apps

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

Reference in `app.yml` (replace `my-app` with your app name):
```yaml
vars:
  app_chart_file: "{{ inventory_dir }}/apps/my-app/Chart.yml"
  app_values_file: "{{ inventory_dir }}/apps/my-app/values.yml"
  prerequisites_playbook: "{{ inventory_dir }}/apps/my-app/prerequisites.yml"
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

### Storage Selection

The infrastructure uses **NFS-based storage** backed by Beelink's MergerFS pool. All persistent volumes use the `nfs` storage class by default.

#### NFS Storage (Default)

**Use for all persistent volumes:**
- Application configs and databases
- Media libraries (movies, TV shows, photos)
- File storage (Nextcloud, etc.)

**Configuration:**
```yaml
persistence:
  config:
    enabled: true
    type: persistentVolumeClaim
    storageClass: nfs  # Default storage class
    size: 5Gi
    accessMode: ReadWriteOnce

  data:
    enabled: true
    type: persistentVolumeClaim
    storageClass: nfs
    size: 500Gi
    accessMode: ReadWriteMany  # NFS supports multi-node access
```

**Backups**: All NFS volumes backed up via restic to MinIO S3:
- **Schedule**: Daily 3:00 AM
- **Retention**: 7 daily, 4 weekly, 6 monthly snapshots
- **Backup location**: s3://minio/restic-backups/
- **Features**: Deduplication, incremental backups

**Storage on Beelink:**
- `/mnt/storage/k8s-apps/` - App configs and databases
- `/mnt/storage/media/` - Media files

#### Storage Class Reference

| Storage Class | Type | Capacity | Redundancy | Backup Method | Best For |
|---------------|------|----------|------------|---------------|----------|
| `nfs` (default) | NFS (Beelink) | 4TB | SnapRAID parity | restic → MinIO S3 | All persistent volumes |
| `local-path` | Local | Node-specific | None | None | Temporary data only |

#### Best Practices

1. **Use default storage class**: `nfs` is the cluster default
2. **SSH access available**: Can manage files directly via SSH on Beelink
3. **Hardlink support**: All volumes on same filesystem
4. **Incremental backups**: restic deduplicates and compresses
5. **Test restores**: Validate backup/restore workflow

#### Related Documentation

- [Storage Architecture Guide](./storage-architecture.md) - Complete storage architecture details
- [Disaster Recovery Guide](./disaster-recovery.md) - Backup and restore procedures
- [Project Structure](./project-structure.md#storage-architecture-strategy) - Storage overview
- [Media Stack Guide](./media-stack-complete-guide.md) - NFS storage example

## Troubleshooting

### App Won't Deploy

1. **Check Helm repository exists:**
   ```bash
   helm repo list
   ```

2. **Validate Chart.yml:**
   ```bash
   make lint-apps
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

## Makefile Commands Reference

### lint-apps
Lint and validate all app configurations including YAML syntax and Helm chart templates.

```bash
make lint-apps
```

**Example output:**
```
=== Linting YAML Files ===
Checking apps/test-app/values.yml...
Checking apps/demo-app/values.yml...

=== Validating Helm Chart Templates ===

--- Rendering demo-app (bitnami/nginx:22.2.3) ---
[Full YAML manifests displayed...]

✅ All apps validated successfully
```

**When to use:** Before deploying any app to catch YAML syntax errors, template rendering issues, and validate chart compatibility.

**Automated:** Runs automatically in pre-commit hooks when values files are changed.

**Note:** Shows full rendered manifests for debugging. Validates both YAML syntax and Helm template rendering.

---

### app-deploy
Deploy a specific application to the K3s cluster.

```bash
make app-deploy APP=test-app
```

**Example output:**
```
Deploying test-app...
PLAY [Deploy Helm Application] *************************
TASK [Display deployment information] ******************
╔═══════════════════════════════════════════════╗
║ Helm Application Deployment                  ║
║ Chart: bitnami/nginx                          ║
║ Version: 18.2.5                               ║
║ Release: test-app                             ║
║ Namespace: applications                       ║
╚═══════════════════════════════════════════════╝
...
✅ Successfully deployed test-app
```

**Parameters:**
- `APP` (required): Name of the app directory in `apps/`

**When to use:** Initial deployment of a new app, or redeployment after configuration changes.

---

### app-upgrade
Upgrade an existing app with new values or chart version.

```bash
make app-upgrade APP=test-app
```

**Example:**
```bash
# Update chart version in apps/test-app/Chart.yml
vim apps/test-app/Chart.yml

# Apply the upgrade
make app-upgrade APP=test-app
```

**Parameters:**
- `APP` (required): Name of the app to upgrade

**When to use:** After modifying Chart.yml or values.yml for an already-deployed app.

---

### app-list
List all deployed Helm releases across all namespaces.

```bash
make app-list
```

**Example output:**
```
Deployed applications:
NAME            NAMESPACE       REVISION    UPDATED                             STATUS      CHART           APP VERSION
test-app        applications    1           2025-11-03 18:30:45 +0100 CET       deployed    nginx-18.2.5    1.27.3
cert-manager    cert-manager    1           2025-11-03 07:00:15 +0100 CET       deployed    cert-manager... v1.13.2
nfs-storage     nfs-storage     1           2025-11-03 06:58:43 +0100 CET       deployed    nfs-subdir...   4.0.18
```

**When to use:** To see what apps are currently deployed and their versions.

---

### app-status
Show detailed status of a specific app.

```bash
make app-status APP=test-app
```

**Example output:**
```
Status of test-app:
Helm status:
NAME: test-app
LAST DEPLOYED: Mon Nov  3 18:30:45 2025
NAMESPACE: applications
STATUS: deployed
REVISION: 1
...

Pods:
NAME                        READY   STATUS    RESTARTS   AGE
test-app-nginx-7d4c8f-xyz   1/1     Running   0          5m
```

**Parameters:**
- `APP` (required): Name of the app

**When to use:** To troubleshoot deployment issues or verify app health.

---

## Complete Workflow Example

Deploying a new app from scratch:

```bash
# 1. Create app directory
mkdir -p apps/my-app
cd apps/my-app

# 2. Create Chart.yml (use your editor)
cat > Chart.yml <<EOF
---
chart_repository: bitnami
chart_name: redis
chart_version: 20.5.0
release_name: my-app
namespace: applications
description: "My Redis cache"
EOF

# 3. Create values.yml
cat > values.yml <<EOF
---
replicaCount: 1
nodeSelector:
  kubernetes.io/os: linux
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi
EOF

# 4. Create app.yml playbook
cat > app.yml <<EOF
---
- name: Deploy My App
  import_playbook: ../../playbooks/deploy-helm-app.yml
  vars:
    app_chart_file: "{{ inventory_dir }}/apps/my-app/Chart.yml"
    app_values_file: "{{ inventory_dir }}/apps/my-app/values.yml"
EOF

# 5. Validate
make lint-apps

# 6. Deploy
make app-deploy APP=my-app

# 7. Check status
make app-status APP=my-app

# 8. List all apps
make app-list
```

## See Also

- [Helm Standards](helm-standards.md) - Values file organization and conventions
- [Project Structure](project-structure.md) - Overall repository organization
- [Playbook Guidelines](playbook-guidelines.md) - Ansible best practices
