# Required Vault Variables for Restic Backup

Before running the restic backup setup playbook, add these variables to `group_vars/all/vault.yml`.

**Note**: The MinIO user (`restic-backup`), bucket (`restic-backups`), and service account will be created automatically during MinIO installation (Phase 5) if these vault variables are configured beforehand.

## Add Variables to Vault:

```bash
# Edit vault file
uv run ansible-vault edit group_vars/all/vault.yml
```

## Variables to Add:

```yaml
# Restic backup password (encrypts the restic repository)
vault_restic_password: "your-secure-restic-password-here"

# Restic backup user password (MinIO user account)
vault_restic_backup_password: "your-secure-user-password-here"

# MinIO S3 service account credentials (S3 API access)
# Choose your own access/secret keys (16+ characters recommended)
vault_restic_s3_access_key: "restic-s3-access-key-minimum-16-chars"
vault_restic_s3_secret_key: "restic-s3-secret-key-minimum-16-chars"
```

## What Gets Created Automatically:

When you run `make site` or `make minio`, the following are created automatically:

1. **MinIO Bucket**: `restic-backups` (private, no object locking)
2. **MinIO User**: `restic-backup` with read-write access to `restic-backups` bucket
3. **Service Account**: S3 API credentials linked to `restic-backup` user

This is configured in `group_vars/nas/main.yml`:
- `minio_buckets` - includes `restic-backups`
- `minio_users` - includes `restic-backup` user
- `minio_service_accounts` - includes restic service account

## Setup Order:

1. Add vault variables (this file's instructions)
2. Run MinIO setup: `make minio` (or `make site` for full infrastructure)
3. Run restic backup setup: `make backup-setup`
4. Verify: `ssh beelink "restic snapshots"`

## MinIO Internal Domain:

The MinIO domain is configured in `group_vars/nas/main.yml`:
```yaml
minio_internal_domain: "minio.jardoole.xyz"
```

This should already be set correctly.

## Generating Secure Keys:

Generate random keys for access/secret keys:

```bash
# Generate access key (20 characters)
openssl rand -base64 15

# Generate secret key (40 characters)
openssl rand -base64 30
```

Use these values for `vault_restic_s3_access_key` and `vault_restic_s3_secret_key`.
