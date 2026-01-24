# Ansible Vault Usage

**CRITICAL**: All secrets MUST be encrypted with ansible-vault before committing to the repository.

## When to Use Ansible Vault

Encrypt these types of data:

- **Passwords**: Database, service accounts, user passwords
- **API tokens**: Cloud providers, third-party services
- **Encryption keys**: LUKS keys, TLS private keys
- **Sensitive configuration**: Email addresses for certificates, internal domains

## Variable Naming Convention

All vault-encrypted variables MUST use the `vault_` prefix:

```yaml
# Good examples
vault_minio_root_password: "secret123"
vault_cloudflare_api_token: "abc123xyz"
vault_beelink_luks_key_path: "/path/to/key"

# Bad examples (missing vault_ prefix)
minio_password: "secret123"  # WRONG
api_token: "abc123xyz"  # WRONG
```

## Vault Password Location

The master vault password is stored in `vault_passwords/all.txt` (gitignored).

- **DO NOT** read or expose this file
- **DO NOT** commit this file to the repository
- Ansible automatically uses this password via `ansible.cfg`

## Common Vault Commands

```bash
# Create new encrypted file
uv run ansible-vault create group_vars/groupname/vault.yml

# Edit existing encrypted file
uv run ansible-vault edit group_vars/groupname/vault.yml

# Encrypt existing plaintext file
uv run ansible-vault encrypt files/secret-key.bin

# Decrypt file temporarily (for debugging only)
uv run ansible-vault decrypt files/secret-key.bin

# View encrypted file without editing
uv run ansible-vault view group_vars/groupname/vault.yml
```

## Vault File Structure

**Location pattern:** `group_vars/<group_name>/vault.yml`

**Example structure** (see `example_vault.yml`):

```yaml
# MinIO credentials
vault_minio_root_password: "***"

# K3s cluster credentials
vault_k3s_control_token: "***"

# API tokens
vault_cloudflare_api_token: "***"
```

## Using Vault Variables in Playbooks

Reference vault variables in non-encrypted files:

```yaml
# group_vars/nas/main.yml (not encrypted)
minio_root_password: "{{ vault_minio_root_password }}"
cloudflare_api_token: "{{ vault_cloudflare_api_token }}"
```

## Encrypting Binary Files

For binary secrets (encryption keys, certificates):

```bash
# Generate key
dd if=/dev/urandom of=files/luks-key.bin bs=4096 count=1

# Encrypt with ansible-vault
uv run ansible-vault encrypt files/luks-key.bin

# Reference in vault.yml
vault_luks_key_path: "{{ playbook_dir }}/files/luks-key.bin"
```

Ansible automatically decrypts vault-encrypted files during playbook execution.

## Best Practices

1. **Never commit unencrypted secrets** - Always encrypt before `git add`
2. **Use descriptive variable names** - `vault_service_purpose_credential`
3. **Keep vault.yml organized** - Group related secrets with comments
4. **Test decryption** - Run `ansible-vault view` before committing
5. **Separate vault files** - One per group_vars directory for clarity
