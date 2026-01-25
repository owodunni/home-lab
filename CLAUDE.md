# CLAUDE.md

Guidance for Claude Code when working with this repository.

## Important

- ALL instructions within this document MUST BE FOLLOWED
- DO NOT edit more code than necessary
- DO NOT WASTE TOKENS, be succinct and concise
- Respect all .claudeignore entries without exception
- **NEVER read secrets** from Ansible Vault or Kubernetes Secrets. If asked to retrieve or debug secrets, provide the command for the user to run instead (e.g., `uv run ansible-vault view`, `kubectl get secret -o jsonpath`)

## Development Partnership

We build production code together. I handle implementation details while you guide architecture and catch complexity early.

## Core Workflow: Research -> Plan -> Implement -> Validate

**Start every feature with:** "Let me research the codebase and create a plan before implementing."

1. **Research** - Understand existing patterns and architecture
2. **Plan** - Propose approach and verify with you
3. **Implement** - Build with tests and error handling
4. **Validate** - ALWAYS run formatters, linters, and tests after implementation

## Repository Overview

Home lab automation using Ansible to provision Raspberry Pi CM5 cluster and Beelink worker.

**Infrastructure:**

- **Control plane**: pi-cm5-1, pi-cm5-2, pi-cm5-3 (hosts.ini [control_plane])
- **Workers**: beelink (hosts.ini [workers])
- **NAS**: pi-cm5-4 (hosts.ini [nas])

## Architecture Principles

**MANDATORY**: Before structural changes:

1. **Read** `docs/project-structure.md` - current architecture
2. **Update** `docs/project-structure.md` after changes
3. **Verify** changes align with established patterns

**MANDATORY**: Before editing playbooks or group_vars:

1. **Read** `docs/playbook-guidelines.md` - documentation standards
2. **Follow** established patterns from `upgrade.yml`
3. **Document** WHY decisions were made

**Prefer explicit over implicit:**

- Clear function names over clever abstractions
- Obvious data flow over hidden magic
- **Idempotent playbooks**: Safe to run multiple times

## Git Commit Guidelines

**MANDATORY**: Read `docs/git-commit-guidelines.md` before each commit.

**Pre-commit workflow:**

1. Stage files: `git add .`
2. Run pre-commit: `make precommit`
3. Fix issues reported by linters
4. Stage fixes: `git add .`
5. Commit with proper message format

## Maximize Efficiency

- **Parallel operations:** Run multiple searches, reads, greps in single messages
- **Multiple agents:** Split complex tasks
- **Batch similar work:** Group related file edits

## Problem Solving

**When stuck:** Stop. The simple solution is usually correct.

**When uncertain:** "Let me ultrathink about this architecture."

**When choosing:** "I see approach A (simple) vs B (flexible). Which do you prefer?"

## Development Workflow

- **Dependencies**: `make setup` (Python deps + Ansible collections)
- **Static analysis**: `make precommit` (linters and syntax checks)
- **Dry runs**: Test playbook logic before execution

## Ansible Vault

**CRITICAL**: All secrets MUST be encrypted with ansible-vault.

- Use `vault_` prefix for all encrypted variables
- See [docs/ansible-vault.md](docs/ansible-vault.md) for complete guide

## Backup Strategy

Two backup methods are used depending on data type:

| Data Type | Method | Target Bucket |
|-----------|--------|---------------|
| Files (configs, media) | Backrest (restic) | `restic-backups` |
| PostgreSQL databases | CNPG native (barman) | `postgres-backups` |

**Why separate methods?**
- Backrest: File-level incremental backups with deduplication
- CNPG: Database-aware backups with point-in-time recovery (PITR)

See [docs/disaster-recovery.md](docs/disaster-recovery.md) for recovery procedures.

## CRITICAL: Ansible Execution Restrictions

**NEVER run playbooks or make tasks except `make precommit`** - they consume tokens rapidly.

**Approved commands only:**

- `make precommit` - Static analysis and linting
- `uv run ansible [host] -a "[command]"` - Single host checks

**FORBIDDEN commands:**

- `make site`, `make minio`, `make k3s-cluster` - Infrastructure deployment
- `make teardown` - Infrastructure removal
- Any `ansible-playbook` execution
- Any make target that runs playbooks

**Why:** Playbooks can consume 10k+ tokens per run. Always ask user to run manually.

## CRITICAL: Kubernetes Deployment Restrictions

**NEVER apply resources directly with `kubectl apply`** - all changes must go through deployment scripts.

**Forbidden:**

- `kubectl apply -f` for creating/updating resources
- `kubectl patch` for modifying resources
- `kubectl edit` for live editing
- Any direct resource modification

**Required approach:**

1. Edit the source files (prerequisites.yml, values.yml, etc.)
2. Provide the user with the deployment command (`make app-deploy APP=<name>`)
3. Let the user run the deployment

**Why:** Direct kubectl changes create drift between code and cluster state. All changes must be reflected in version-controlled files.

## Core Documentation

- [docs/INDEX.md](docs/INDEX.md) - **Full documentation index**
- [docs/project-structure.md](docs/project-structure.md) - **MANDATORY** - Architecture
- [docs/app-deployment-guide.md](docs/app-deployment-guide.md) - K8s app deployment
- [docs/helm-standards.md](docs/helm-standards.md) - Helm conventions

## Deploying Apps to K3s

Apps live in `apps/` directory with standardized Helm chart structure.

**Quick commands:**

```bash
ls apps/                          # List apps
make app-deploy APP=<app-name>    # Deploy
make app-status APP=<app-name>    # Status
```

**Key guidelines:**

- Pin exact versions in Chart.yml
- Use `*common-resource-limits-*` anchors
- All secrets via vault (`{{ vault_app_secret }}`)
- HTTPS ingress with cert-manager
- Use `storageClass: nfs` for persistent storage

**Adding new Helm repositories:**

When an app requires a new Helm repository not yet in the cluster:

1. Add the repo to `playbooks/k3s/02-helm-setup.yml`
2. User runs `make k3s-helm-setup` to install the repo
3. Then deploy the app with `make app-deploy APP=<app-name>`

See [docs/helm-standards.md](docs/helm-standards.md) for repository details.
See [docs/app-deployment-guide.md](docs/app-deployment-guide.md) for complete workflow.

## Progress Tracking

- **TodoWrite** for task management
- **Clear naming** in all code

Focus on maintainable solutions over clever abstractions.
