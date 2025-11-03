# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Important
- ALL instructions within this document MUST BE FOLLOWED, these are not optional unless explicitly stated.
- DO NOT edit more code than you have to.
- DO NOT WASTE TOKENS, be succinct and concise.
- Respect all .claudeignore entries without exception

## Development Partnership

We build production code together. I handle implementation details while you guide architecture and catch complexity early.

## Core Workflow: Research → Plan → Implement → Validate

**Start every feature with:** "Let me research the codebase and create a plan before implementing."

1. **Research** - Understand existing patterns and architecture
2. **Plan** - Propose approach and verify with you
3. **Implement** - Build with tests and error handling
4. **Validate** - ALWAYS run formatters, linters, and tests after implementation

## Repository Overview

This is a home lab automation repository using Ansible to provision and manage a cluster of Raspberry Pi CM5 (Compute Module 5) devices. The infrastructure consists of:

- **Control plane nodes**: pi-cm5-1, pi-cm5-2, pi-cm5-3 (defined in hosts.ini under [control_plane])
- **NAS node**: pi-cm5-4 (defined in hosts.ini under [nas])

## Code Organization

**Keep functions small and focused:**
- If you need comments to explain sections, split into functions
- Group related functionality into clear packages
- Prefer many small files over few large ones

## Architecture Principles

**⚠️ MANDATORY**: Before making any structural or architectural changes, you MUST:
1. **Read** `docs/project-structure.md` to understand current architecture
2. **Update** `docs/project-structure.md` after implementing changes
3. **Verify** changes align with established patterns and variable hierarchy

**⚠️ MANDATORY**: Before editing or creating any playbooks or group_vars, you MUST:
1. **Read** `docs/playbook-guidelines.md` to understand documentation standards
2. **Follow** the established documentation patterns from `upgrade.yml`
3. **Document** WHY decisions were made, not just WHAT was implemented

**Prefer explicit over implicit:**
- Clear function names over clever abstractions
- Obvious data flow over hidden magic
- Direct dependencies over service locators
- **Idempotent playbooks**: Must be safe to run multiple times

## Git Commit Guidelines

**⚠️ MANDATORY**: Read `docs/git-commit-guidelines.md` before each commit.

**Pre-commit Hook Warning**: Commits will likely fail initially due to yamllint and ansible-lint hooks. Follow this workflow:

1. **Stage files**: `git add .`
2. **Run pre-commit**: `make precommit`
3. **Fix any issues** reported by linters
4. **Stage fixes**: `git add .`
5. **Commit**: Use proper message format from guidelines

## Maximize Efficiency

**Parallel operations:** Run multiple searches, reads, and greps in single messages
**Multiple agents:** Split complex tasks - one for tests, one for implementation
**Batch similar work:** Group related file edits together

## Problem Solving

**When stuck:** Stop. The simple solution is usually correct.

**When uncertain:** "Let me ultrathink about this architecture."

**When choosing:** "I see approach A (simple) vs B (flexible). Which do you prefer?"

Your redirects prevent over-engineering. When uncertain about implementation, stop and ask for guidance.

## Development Workflow

- **Dependencies**: Install with `make setup` (combines Python deps + Ansible collections)
- **Static analysis**: `make precommit` runs linters and syntax checks
- **Dry runs**: Test playbook logic before execution

## Ansible Vault Usage

**⚠️ CRITICAL**: All secrets MUST be encrypted with ansible-vault before committing to the repository.

### When to Use Ansible Vault

Encrypt these types of data:
- **Passwords**: Database, service accounts, user passwords
- **API tokens**: Cloud providers, third-party services
- **Encryption keys**: LUKS keys, TLS private keys
- **Sensitive configuration**: Email addresses for certificates, internal domains

### Variable Naming Convention

All vault-encrypted variables MUST use the `vault_` prefix:
```yaml
# Good examples
vault_minio_root_password: "secret123"
vault_cloudflare_api_token: "abc123xyz"
vault_beelink_luks_key_path: "/path/to/key"

# Bad examples (missing vault_ prefix)
minio_password: "secret123"  # WRONG
api_token: "abc123xyz"       # WRONG
```

### Vault Password Location

The master vault password is stored in `vault_passwords/all.txt` (gitignored).
- **DO NOT** read or expose this file
- **DO NOT** commit this file to the repository
- Ansible automatically uses this password via `ansible.cfg`

### Common Vault Commands

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

### Vault File Structure

**Location pattern:** `group_vars/<group_name>/vault.yml`

**Example structure** (see `example_vault.yml`):
```yaml
# MinIO credentials
vault_minio_root_password: "***"
vault_longhorn_backup_password: "***"

# K3s cluster credentials
vault_k3s_control_token: "***"

# API tokens
vault_cloudflare_api_token: "***"
```

### Using Vault Variables in Playbooks

Reference vault variables in non-encrypted files:
```yaml
# group_vars/nas/main.yml (not encrypted)
minio_root_password: "{{ vault_minio_root_password }}"
cloudflare_api_token: "{{ vault_cloudflare_api_token }}"
```

### Encrypting Binary Files

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

### Best Practices

1. **Never commit unencrypted secrets** - Always encrypt before `git add`
2. **Use descriptive variable names** - `vault_service_purpose_credential`
3. **Keep vault.yml organized** - Group related secrets with comments
4. **Test decryption** - Run `ansible-vault view` before committing
5. **Separate vault files** - One per group_vars directory for clarity

## ⚠️ CRITICAL: Ansible Execution Restrictions

**NEVER run playbooks or make tasks except `make precommit`** - they consume tokens rapidly and can burn through your budget in minutes.

**Approved commands only:**
- `make precommit` - Static analysis and linting
- `uv run ansible [host] -a "[command]"` - Single host checks (like `systemctl status`, `ls`, etc.)

**FORBIDDEN commands (token burning):**
- `make site`, `make minio`, `make k3s-cluster` - Full infrastructure deployment
- `make teardown` - Infrastructure removal
- Any `ansible-playbook` execution
- Any make target that runs playbooks

**Why this matters:** Ansible playbooks with multiple hosts and complex tasks can consume 10k+ tokens per run. Always ask user to run these commands manually.

## Core Files

To understand the project structure read

- `docs/project-structure.md`: **MANDATORY READ** - Complete project architecture and variable system
- `docs/app-deployment-guide.md`: Kubernetes app deployment workflow
- `docs/helm-standards.md`: Helm chart standards and conventions

## Deploying a New App to K3s

The `apps/` directory contains standardized Helm chart deployments. Each app follows the same structure for consistency.

### Quick Start

```bash
# List available apps
ls apps/

# Deploy an app
make app-deploy APP=<app-name>

# Check status
make app-status APP=<app-name>
```

### Creating a New App

1. **Create app directory:**
   ```bash
   mkdir -p apps/my-app
   cd apps/my-app
   ```

2. **Create Chart.yml** (chart metadata):
   ```yaml
   ---
   chart_repository: bitnami
   chart_name: nginx
   chart_version: 15.1.0
   release_name: my-app
   namespace: applications
   description: "My application description"
   ```

3. **Create values.yml** (Helm values):
   ```yaml
   ---
   # Use common resource limits
   <<: *common-resource-limits-medium

   replicaCount: 1

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

4. **Create app.yml** (deployment playbook):
   ```yaml
   ---
   - name: Deploy My App
     import_playbook: ../../playbooks/deploy-helm-app.yml
     vars:
       app_chart_file: "{{ playbook_dir }}/Chart.yml"
       app_values_file: "{{ playbook_dir }}/values.yml"
   ```

5. **Create README.md:**
   ```markdown
   # My App

   Brief description.

   ## Dependencies
   - Longhorn (storage)
   - cert-manager (TLS)

   ## Access
   - URL: https://my-app.jardoole.xyz
   ```

6. **Deploy:**
   ```bash
   make helm-lint                # Validate values
   make app-deploy APP=my-app    # Deploy
   ```

### Important Guidelines

- **Pin exact versions** in Chart.yml (e.g., `1.13.2` not `~1.13.0`)
- **Use common resource limits** - Reference `*common-resource-limits-*` anchors
- **All secrets use vault** - Reference `{{ vault_app_secret }}` pattern
- **HTTPS ingress** - Use cert-manager annotations for auto TLS
- **ResourceQuota compliance** - All containers MUST specify resource limits

See [App Deployment Guide](docs/app-deployment-guide.md) for complete workflow.

## Progress Tracking

- **TodoWrite** for task management
- **Clear naming** in all code

Focus on maintainable solutions over clever abstractions.
