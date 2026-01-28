# Nextcloud File Sync & Share

Nextcloud is an open-source file sync and share platform with Authentik SSO integration.

## Architecture

| Component | Configuration |
|-----------|---------------|
| Chart | `nextcloud/nextcloud` v6.6.0 |
| PostgreSQL | CloudNative-PG cluster with Barman Cloud Plugin |
| Redis | Bitnami Redis for caching/locking |
| Email | Gmail SMTP via cluster config |
| Ingress | `cloud.jardoole.xyz` with TLS |
| SSO | Authentik OIDC via `user_oidc` app |

## Vault Secrets Required

Before deploying, add these secrets to `group_vars/all/vault.yml`:

```yaml
vault_nextcloud_admin_username: "admin"
vault_nextcloud_admin_password: "<secure-password>"
vault_nextcloud_db_password: "<secure-password>"
vault_nextcloud_redis_password: "<secure-password>"
```

Generate passwords with:

```bash
openssl rand -base64 32 | tr -d '\n'
```

**Note:** `vault_cnpg_s3_access_key`, `vault_cnpg_s3_secret_key`, `vault_smtp_username`, and `vault_smtp_password` must already exist.

## Deployment

1. Ensure CNPG with Barman Cloud Plugin is deployed:
   ```bash
   make app-deploy APP=cloudnative-pg
   ```

2. Add Helm repository (first time only):
   ```bash
   make k3s-helm-setup
   ```

3. Add vault secrets:
   ```bash
   uv run ansible-vault edit group_vars/all/vault.yml
   ```

4. Deploy:
   ```bash
   make app-deploy APP=nextcloud
   ```

## Verification

```bash
# Check PostgreSQL cluster
kubectl get cluster -n nextcloud

# Check ObjectStore for backups
kubectl get objectstore -n nextcloud

# Check pods
kubectl get pods -n nextcloud

# Check ingress
kubectl get ingress -n nextcloud

# View logs
kubectl logs -n nextcloud -l app.kubernetes.io/name=nextcloud
```

## Post-Deployment: Authentik SSO Setup

### 1. Create Authentik Provider

In Authentik UI (`https://authentik.jardoole.xyz`):

1. Navigate to **Applications > Providers > Create**
2. Select **OAuth2/OpenID Provider**
3. Configure:
   - Name: `nextcloud`
   - Authorization flow: `default-provider-authorization-implicit-consent`
   - Client type: `Confidential`
   - Redirect URIs: `https://cloud.jardoole.xyz/apps/user_oidc/code`
   - Scopes: `openid`, `email`, `profile`

### 2. Create Authentik Application

1. Navigate to **Applications > Applications > Create**
2. Configure:
   - Name: `Nextcloud`
   - Slug: `nextcloud`
   - Provider: `nextcloud`
   - Launch URL: `https://cloud.jardoole.xyz`

### 3. Install Nextcloud OIDC App

```bash
# Get the pod name
POD=$(kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}')

# Install user_oidc app
kubectl exec -n nextcloud $POD -- php occ app:install user_oidc
kubectl exec -n nextcloud $POD -- php occ app:enable user_oidc
```

### 4. Configure OIDC in Nextcloud

1. Log into Nextcloud as admin
2. Navigate to **Settings > Administration > OpenID Connect**
3. Add provider:
   - Identifier: `authentik`
   - Client ID: (from Authentik provider)
   - Client Secret: (from Authentik provider)
   - Discovery endpoint: `https://authentik.jardoole.xyz/application/o/nextcloud/.well-known/openid-configuration`
   - Scopes: `openid email profile`

## Components

- **Nextcloud**: Main application (FPM + nginx)
- **PostgreSQL**: CNPG-managed database with Barman Cloud Plugin backups
- **Redis**: Session caching and file locking
- **Cron**: Background job processing

## Storage

| Volume | Storage Class | Size | Purpose |
|--------|---------------|------|---------|
| Data | NFS | 100Gi | User files |
| Redis | NFS | 1Gi | Cache persistence |
| PostgreSQL | local-path | 2Gi | Database |

## Backup Architecture

- **PostgreSQL**: Barman Cloud Plugin to MinIO `postgres-backups/nextcloud`
- **Files**: Configure Backrest for NFS volume backup to `restic-backups`

## Troubleshooting

### Check Nextcloud Status

```bash
kubectl exec -n nextcloud $POD -- php occ status
```

### View Nextcloud Logs

```bash
kubectl logs -n nextcloud -l app.kubernetes.io/name=nextcloud -f
```

### Database Connectivity

```bash
kubectl exec -n nextcloud $POD -- php occ db:convert-filecache-bigint
```

### Reset Admin Password

```bash
kubectl exec -n nextcloud $POD -- php occ user:resetpassword admin
```
