# Authentik Identity Provider

Authentik is an open-source Identity Provider that provides SSO, SAML, OIDC, and LDAP support.

## Architecture

| Component | Configuration |
|-----------|---------------|
| Chart | `authentik/authentik` v2025.12.1 |
| PostgreSQL | CloudNative-PG cluster with Barman Cloud Plugin |
| Redis | Not required (removed in Authentik 2025.10) |
| Email | Gmail SMTP via cluster config |
| Ingress | `authentik.jardoole.xyz` with TLS |

## Vault Secrets Required

Before deploying, add these secrets to `group_vars/all/vault.yml`:

```yaml
vault_authentik_secret_key: "<50-char-random>"
vault_authentik_db_password: "<secure-password>"
```

Generate with:

```bash
# Secret key
openssl rand -base64 60 | tr -d '\n' | head -c 50

# DB password
openssl rand -base64 32 | tr -d '\n'
```

**Note:** `vault_cnpg_s3_access_key` and `vault_cnpg_s3_secret_key` must already exist for PostgreSQL backups.

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
   make app-deploy APP=authentik
   ```

5. Initial setup: Navigate to `https://authentik.jardoole.xyz/if/flow/initial-setup/`

## Verification

```bash
# Check PostgreSQL cluster
kubectl get cluster -n authentik

# Check ObjectStore for backups
kubectl get objectstore -n authentik

# Check pods
kubectl get pods -n authentik

# Check ingress
kubectl get ingress -n authentik

# View logs
kubectl logs -n authentik -l app.kubernetes.io/name=authentik-server
```

## Components

- **Server**: Handles web UI and API requests
- **Worker**: Background tasks (email, sync, etc.)
- **PostgreSQL**: CNPG-managed database with Barman Cloud Plugin backups

## Email Configuration

Email is configured via environment variables from `authentik-secrets`:
- Uses cluster-wide SMTP settings from `group_vars/all/main.yml`
- Gmail SMTP with TLS on port 587
- From address: `alert@jardoole.xyz`

## Backup Architecture

This deployment uses the **Barman Cloud Plugin** for PostgreSQL backups:

1. **ObjectStore CR** (`authentik-db-backup`) - Defines S3 backup destination
2. **Cluster plugin config** - References the ObjectStore for WAL archiving

This is the recommended approach replacing the deprecated `spec.backup.barmanObjectStore`.
