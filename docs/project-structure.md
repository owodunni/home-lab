# Home Lab Project Structure

This document describes the organization and architecture of the home lab automation repository using Ansible to manage a cluster of Raspberry Pi CM5 devices.

## Directory Structure

```
home-lab/
├── ansible.cfg                 # Ansible configuration
├── hosts.ini                   # Inventory file defining cluster topology
├── requirements.yml            # External Ansible collections/roles
├── CLAUDE.md                   # AI assistant guidance
├── Makefile                    # Development and deployment commands
├── pyproject.toml              # Python dependencies (UV package manager)
├── uv.lock                     # Lock file for dependencies
├── README.md                   # Project overview
├── docs/                       # Documentation
│   ├── project-structure.md    # This file
│   ├── git-commit-guidelines.md
│   └── playbook-guidelines.md
├── playbooks/                  # Ansible playbooks
│   ├── upgrade.yml             # System upgrade playbook
│   └── unattended-upgrades.yml # Unattended upgrades setup
└── group_vars/                 # Variable configuration
    └── all.yml                 # Variables for all hosts
```

## Infrastructure Overview

### Host Groups
- **cluster**: Computing nodes (pi-cm5-1, pi-cm5-2, pi-cm5-3)
- **nas**: Network-attached storage (pi-cm5-4)
- **all**: All devices in the infrastructure

### Network Architecture
All devices are Raspberry Pi CM5 (Compute Module 5) units managed via SSH with user `alexanderp`.

## Ansible Variables System

### Variable Precedence (Highest to Lowest)
1. **Command line** (`-e var=value`)
2. **host_vars/hostname.yml** (host-specific variables)
3. **group_vars/groupname.yml** (group-specific variables)
4. **group_vars/all.yml** (variables for all hosts)
5. **Role defaults** (defined in roles)

### Variable Categories

#### Configuration Variables
Variables that control behavior and should be customizable:
```yaml
# Good examples
unattended_automatic_reboot: true
unattended_automatic_reboot_time: "03:00"
backup_retention_days: 30
monitoring_enabled: true
```

#### Infrastructure Variables
Variables that describe the environment:
```yaml
# Good examples
cluster_nodes:
  - pi-cm5-1
  - pi-cm5-2
  - pi-cm5-3
nas_storage_path: "/mnt/storage"
network_domain: "homelab.local"
```

#### Avoid Hardcoding
- File paths that might change
- Service ports that might conflict
- Credentials (use Ansible Vault)
- Environment-specific values

### group_vars Usage Patterns

#### group_vars/all.yml
Unified configuration for all hosts:
```yaml
---
# Unattended upgrades configuration for all Pi cluster hosts

# Trusted update sources - security updates prioritized
unattended_origins_patterns:
  - 'origin=Debian,codename=${distro_codename},label=Debian-Security'
  - 'origin=Debian,codename=${distro_codename},label=Debian'
  - 'origin=Raspbian,codename=${distro_codename},label=Raspbian'

# Automatic reboot after updates requiring restart
unattended_automatic_reboot: true
unattended_automatic_reboot_time: "02:00"
```

#### host_vars/ (When to Use)
Create `host_vars/hostname.yml` only for truly unique per-host settings:
```yaml
---
# host_vars/pi-cm5-4.yml (if NAS needs different behavior later)
storage_devices:
  - /dev/sda1
  - /dev/sdb1

# host_vars/pi-cm5-1.yml
cluster_role: primary
```

**Note**: We currently use a single `group_vars/all.yml` for simplicity. Group-specific files can be added later when actual differences emerge.

## Configuration Strategy

### Environment-Specific Settings
Use group_vars for different environment behaviors:
- **Development**: Aggressive updates, verbose logging
- **Production**: Conservative updates, minimal reboots

### Security Considerations
- Use Ansible Vault for secrets
- Limit update sources to security repositories
- Configure appropriate reboot windows
- Test changes in staging before production

### Scalability Guidelines
- Add new host groups in `hosts.ini`
- Create corresponding `group_vars/newgroup.yml`
- Update playbooks to target appropriate groups
- Maintain variable inheritance hierarchy

## Best Practices

### Variable Naming
- Use descriptive prefixes: `unattended_`, `backup_`, `monitoring_`
- Boolean variables: `enabled`/`disabled` suffix
- Time values: Include units (`_seconds`, `_minutes`)

### File Organization
- One concern per playbook
- Group related variables together
- Comment complex variable structures
- Use consistent YAML formatting

### Documentation
- Document variable purposes in group_vars files
- Explain non-obvious playbook behavior
- Keep this structure document updated
- Reference external role documentation
