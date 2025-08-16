# Git Commit Guidelines

This document establishes commit message standards for the home-lab repository based on [How to Write a Git Commit Message](https://cbea.ms/git-commit/).

## The Seven Rules of a Great Git Commit Message

### 1. Separate subject from body with a blank line

```
Add support for pi-cm5-5 node provisioning

The new node will serve as a backup NAS device with automatic
failover capabilities. Updated inventory and added corresponding
ansible playbook tasks.
```

### 2. Limit the subject line to 50 characters

✅ **Good**: `Fix ansible-lint warnings in upgrade.yml`
❌ **Bad**: `Fix all the ansible-lint warnings that were causing the CI pipeline to fail`

### 3. Capitalize the subject line

✅ **Good**: `Add molecule testing for nginx role`
❌ **Bad**: `add molecule testing for nginx role`

### 4. Do not end the subject line with a period

✅ **Good**: `Update yamllint configuration rules`
❌ **Bad**: `Update yamllint configuration rules.`

### 5. Use the imperative mood in the subject line

Think: "If applied, this commit will _____"

✅ **Good**: `Fix network interface configuration`
❌ **Bad**: `Fixed network interface configuration`
❌ **Bad**: `Fixes network interface configuration`

### 6. Wrap the body at 72 characters

Use your editor's text wrapping functionality to ensure lines don't exceed 72 characters in the commit body.

### 7. Use the body to explain what and why vs. how

Focus on the reasoning behind the change rather than implementation details:

```
Migrate from apt to unattended-upgrades for security updates

The previous manual upgrade approach required intervention during
maintenance windows. Unattended-upgrades provides automatic security
patching while maintaining system stability through staged rollouts.

Addresses security compliance requirement SEC-001.
```

## Infrastructure-Specific Conventions

### Commit Types

Use these prefixes for clarity:

- `feat:` New functionality (new roles, playbooks, services)
- `fix:` Bug fixes (correcting playbook logic, fixing configurations)
- `refactor:` Code restructuring without functional changes
- `docs:` Documentation updates
- `test:` Adding or updating tests (molecule, ansible syntax)
- `ci:` Changes to CI/CD pipeline (.github/workflows, pre-commit)
- `config:` Configuration file updates (ansible.cfg, .yamllint)

### Examples for This Repository

✅ **Good Examples**:
```
feat: Add nginx load balancer role for cluster

fix: Resolve package dependency conflicts in upgrade.yml

refactor: Consolidate common tasks into shared role

test: Add molecule scenarios for database backup role

docs: Update README with new cluster topology

ci: Add ansible-lint to pre-commit pipeline
```

❌ **Bad Examples**:
```
updated stuff
fix
WIP ansible changes
temp commit
```

## Pre-commit Hook Workflow

**⚠️ IMPORTANT**: Commits will likely fail initially due to pre-commit hooks running yamllint and ansible-lint.

### Recommended Workflow

1. **Stage your changes**:
   ```bash
   git add .
   ```

2. **Run pre-commit hooks manually** (before committing):
   ```bash
   make precommit
   ```

3. **Fix any issues** reported by yamllint or ansible-lint

4. **Stage the fixes**:
   ```bash
   git add .
   ```

5. **Commit with proper message**:
   ```bash
   git commit -m "feat: Add backup automation for NAS nodes"
   ```

### Common Pre-commit Failures

- **yamllint**: YAML formatting, indentation, line length
- **ansible-lint**: Ansible best practices, deprecated modules
- **trailing-whitespace**: Remove spaces at end of lines
- **end-of-file-fixer**: Ensure files end with newline

## Atomic Commits

Each commit should represent one logical change:

✅ **Good**: Separate commits for:
- Adding new role
- Updating documentation
- Fixing linting issues

❌ **Bad**: Single commit containing:
- New feature + bug fix + documentation + formatting

## Body Content Guidelines

When writing commit bodies, include:

- **What**: Brief description of the change
- **Why**: Business/technical justification
- **Impact**: What systems/services are affected
- **Testing**: How the change was validated

### Linking to Files and Websites

Use proper markdown links in commit messages:

✅ **Good**: `Updated [git-commit-guidelines.md](./docs/git-commit-guidelines.md) with new rules`
❌ **Bad**: `Updated docs/git-commit-guidelines.md with new rules`

✅ **Good**: `Based on [cbea.ms/git-commit](https://cbea.ms/git-commit/) best practices`
❌ **Bad**: `Based on https://cbea.ms/git-commit/ best practices`

Example:
```
feat: Implement automated certificate renewal

Added Let's Encrypt integration with automatic renewal via cron job.
Previous manual process caused service outages when certificates expired.

Affects: nginx reverse proxy, all HTTPS services
Testing: Validated in molecule test environment with staging certificates
```

## Reference Links

- Original article: https://cbea.ms/git-commit/
- Repository pre-commit configuration: `.pre-commit-config.yaml`
- Ansible best practices: https://docs.ansible.com/ansible/latest/user_guide/playbooks_best_practices.html

---

**Remember**: Good commit messages are love letters to your future self and your teammates. Take the time to write them well.
