# Nextcloud File Sync & Share

Nextcloud is an open-source file sync and share platform with Authentik SSO integration.

## Architecture

| Component | Configuration |
|-----------|---------------|
| Chart | `nextcloud/nextcloud` v8.9.0 |
| PostgreSQL | CloudNative-PG cluster with Barman Cloud Plugin |
| Redis | Bitnami Redis for caching (no persistence) |
| Email | Gmail SMTP via cluster config |
| Ingress | `cloud.jardoole.xyz` with TLS |
| SSO | Authentik OIDC via `user_oidc` app (auto-configured) |

## Vault Secrets Required

Before deploying, add these secrets to `group_vars/all/vault.yml`:

```yaml
# Nextcloud core secrets
vault_nextcloud_admin_username: "admin"
vault_nextcloud_admin_password: "<secure-password>"
vault_nextcloud_db_password: "<secure-password>"
vault_nextcloud_redis_password: "<secure-password>"

# Authentik OIDC (from Authentik provider - see SSO Setup below)
vault_authentik_nextcloud_client_id: "<from-authentik>"
vault_authentik_nextcloud_client_secret: "<from-authentik>"
```

Generate passwords with:

```bash
openssl rand -base64 32 | tr -d '\n'
```

**Note:** `vault_cnpg_s3_access_key`, `vault_cnpg_s3_secret_key`, `vault_smtp_username`, and `vault_smtp_password` must already exist.

## Authentik SSO Setup

**Do this BEFORE deploying Nextcloud** so the postinstall can configure OIDC.

See [docs/authentik-migration.md](../../docs/authentik-migration.md#phase-9-nextcloud-oidc-native) for full instructions.

### Quick Steps:

1. **Create Authentik Provider:**
   - Type: OAuth2/OpenID Provider
   - Name: `nextcloud`
   - Client type: Confidential
   - Redirect URI: `https://cloud.jardoole.xyz/apps/user_oidc/code`
   - Scopes: `openid`, `profile`, `email`

2. **Copy Client ID and Secret** from the created provider

3. **Create Authentik Application:**
   - Name: `Nextcloud`
   - Slug: `nextcloud`
   - Provider: `nextcloud`

4. **Bind groups** (Admins, Users) to the application

5. **Add to vault:**
   ```bash
   uv run ansible-vault edit group_vars/all/vault.yml
   ```

## Deployment

1. Ensure CNPG with Barman Cloud Plugin is deployed:
   ```bash
   make app-deploy APP=cloudnative-pg
   ```

2. Add Helm repository (first time only):
   ```bash
   make k3s-helm-setup
   ```

3. Complete Authentik SSO setup (above) and add all vault secrets

4. Deploy:
   ```bash
   make app-deploy APP=nextcloud
   ```

The postinstall playbook automatically:
- Installs the `user_oidc` Nextcloud app
- Configures the Authentik OIDC provider

## Verification

```bash
# Check pods
kubectl get pods -n nextcloud

# Check PostgreSQL cluster
kubectl get cluster -n nextcloud

# Check ingress
kubectl get ingress -n nextcloud

# View logs
kubectl logs -n nextcloud -l app.kubernetes.io/name=nextcloud
```

## Components

- **Nextcloud**: Main application (Apache)
- **PostgreSQL**: CNPG-managed database with Barman Cloud Plugin backups
- **Redis**: Session caching and file locking (ephemeral)
- **Cron**: Background job processing (sidecar)

## Storage

| Volume | Storage Class | Size | Purpose |
|--------|---------------|------|---------|
| Data | NFS | 100Gi | User files |
| PostgreSQL | local-path | 2Gi | Database |

Note: Redis runs without persistence (it's just a cache).

## Backup Architecture

- **PostgreSQL**: Barman Cloud Plugin to MinIO `postgres-backups/nextcloud`
- **Files**: Configure Backrest for NFS volume backup to `restic-backups`

## Troubleshooting

### Check Nextcloud Status

```bash
POD=$(kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n nextcloud $POD -c nextcloud -- php occ status
```

### Check OIDC Configuration

```bash
kubectl exec -n nextcloud $POD -c nextcloud -- php occ user_oidc:provider authentik
```

### View Nextcloud Logs

```bash
kubectl logs -n nextcloud -l app.kubernetes.io/name=nextcloud -f
```

### Reset Admin Password

```bash
kubectl exec -n nextcloud $POD -c nextcloud -- php occ user:resetpassword admin
```
