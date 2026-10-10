# Paperless-ngx (document management)

Community-supported open-source document management system that transforms physical
documents into a searchable archive. Compute, Postgres 16, Redis, and search indexes
all run on **pi-cm5-2** (co-located with Nextcloud and Vaultwarden). Document files
(media) live on valen's storage pool over an **NFSv3** host mount. TLS is terminated by
the co-located Traefik, **Postgres DB and document media are backed up to Garage S3**
(on valen, mirrored offsite to beelink at the barn), and login is **SSO via Authentik**
(native OIDC through django-allauth).

- Playbook: `playbooks/paperless.yml` (imported by the `applications` layer)
- Role: `roles/paperless/`
- Config: `group_vars/paperless/{main,vault}.yml`
- Inventory group: `[paperless]` → `pi-cm5-2`
- URL: `https://paperless.jardoole.xyz`

---

## Architecture

| Concern | Where |
|---|---|
| App (Paperless-ngx) + Redis + Postgres | `pi-cm5-2`, docker-compose stack at `/opt/paperless` |
| Document media (originals, archives, thumbnails) | valen's MergerFS pool `/mnt/storage/pool/paperless/media`, mounted at `/opt/paperless/media` via NFSv3 |
| Search index (Tantivy/Whoosh) & ML models | local host dir `/opt/paperless/data` |
| Postgres data | local Docker volume `pgdata` |
| DB backup | `pg-dump` → `db-backup` (restic) → Garage `paperless-backup` |
| Media & data backup | `media-backup` (restic) → Garage `paperless-media-backup` |
| Login / SSO | Authentik OIDC (django-allauth) |

### Why Postgres (PostgreSQL 16)
Reuses the platform's standard `pg_dump`→restic logical dump pipeline (the `postgres` backup type,
same as Authentik, Nextcloud, and Vaultwarden). Restic-ing a live database data dir risks crash
inconsistency; logical dumps provide reliable point-in-time restore.

### Why NFS for Media, but Local for Data & DB
Paperless document storage grows over time with PDF scans and OCR archives. Keeping media on
valen's storage pool protects files with SnapRAID parity and offloads capacity from the Pi.
The search index (`data/`) and PostgreSQL database remain strictly local on the Pi to prevent
file locking issues and network mount latency degradation.

---

## SSO — Authentik Setup (Manual, UI)

Create an **OAuth2/OpenID Provider** + **Application** in Authentik:

1. **Provider**:
   * Navigate to **Applications** > **Providers** > **Create**.
   * Type: **OAuth2/OpenID Connect**.
   * Name: `Paperless-ngx Provider`.
   * Authorization flow: default authorization flow.
   * Client type: **Confidential**.
   * Client ID: `paperless` (`paperless_oidc_client_id` in `group_vars/paperless/main.yml`).
   * Client Secret: set to a strong secret and save it for `vault_paperless_oidc_client_secret`.
   * Redirect URI (Strict / Authorization):
     `https://paperless.jardoole.xyz/accounts/oidc/authentik/login/callback/`
   * Scopes: `openid`, `profile`, `email`.
2. **Application**:
   * Navigate to **Applications** > **Applications** > **Create**.
   * Name: `Paperless-ngx`.
   * Slug: `paperless` (matches discovery URI `/application/o/paperless/`).
   * Provider: select `Paperless-ngx Provider`.
   * Launch URL: `https://paperless.jardoole.xyz`.
3. **Application Bindings**:
   * Bind an access group (e.g., `authentik Admins` or dedicated group) so authorized users can log in.

---

## Vault Secrets Setup

Generate the necessary secrets before deploying:

1. **S3 API keys for Garage backups**:
   ```bash
   scripts/garage-keygen.sh vault_paperless_backup_s3
   scripts/garage-keygen.sh vault_paperless_media_backup_s3
   ```
2. **Passwords & Secret Keys**:
   * `vault_paperless_pg_pass`: `openssl rand -hex 16`
   * `vault_paperless_secret_key`: `python3 -c "import secrets; print(secrets.token_urlsafe(64))"`
   * `vault_paperless_restic_password`: `openssl rand -base64 32` (encrypts both restic repositories)
   * `vault_paperless_oidc_client_secret`: Client secret created in Authentik above.

Create or edit `group_vars/paperless/vault.yml` using `ansible-vault` with these keys:

```yaml
vault_paperless_pg_pass: "<generated-pg-pass>"
vault_paperless_secret_key: "<generated-secret-key>"
vault_paperless_restic_password: "<generated-restic-password>"

vault_paperless_backup_s3_access_key: "GK..."
vault_paperless_backup_s3_secret_key: "..."

vault_paperless_media_backup_s3_access_key: "GK..."
vault_paperless_media_backup_s3_secret_key: "..."

vault_paperless_oidc_client_secret: "<authentik-client-secret>"
```

---

## Deployment & Verification

Deploy Paperless-ngx individually:
```bash
make app service=paperless
```

Verify backups:
```bash
make run-backups SERVICE=paperless     # trigger initial backup run
make verify-backups SERVICE=paperless  # check snapshot integrity and freshness
make drill SERVICE=paperless           # non-destructive restore drill to scratch
```
