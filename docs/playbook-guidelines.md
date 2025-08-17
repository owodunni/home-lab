# Playbook Documentation Guidelines

Documentation standards for Ansible playbooks and group_vars files. Follow the principle: **explain WHY, not just WHAT**.

## Required Elements

### 1. File Header
```yaml
---
# [Purpose] - What this accomplishes
# [Context] - When to use it
```

### 2. Task Documentation
- **Descriptive names**: `Update apt package cache (if older than 24 hours)`
- **Pre-task comments**: Explain WHY for non-obvious tasks
- **Safety warnings**: Mark destructive operations with `# WARNING:`
- **External links**: Reference official docs for complex modules

### 3. Parameter Documentation
- **Non-obvious values**: Explain timeouts, thresholds, units
- **Inline comments**: `cache_valid_time: 86400 # 24h in seconds`

### 4. group_vars Files
- **File header**: Purpose and scope
- **Variable comments**: What each controls and why
- **Keep concise**: One line comments preferred

## Good Examples

```yaml
# cache_valid_time prevents unnecessary network traffic during frequent runs
- name: Update apt package cache (if older than 24 hours)
  ansible.builtin.apt:
    cache_valid_time: 86400 # 24h in seconds

# WARNING: This will reboot the system if updates require it
- name: Reboot the server (if required)
  ansible.builtin.reboot:
```

## Avoid
- Obvious comments: `# Install package`
- Missing safety warnings on destructive tasks
- No explanation for non-standard parameter values
- Wall-of-text documentation

## Include
- Links to best practices, documentation, blog posts

## Quality Check
- [ ] File header explains purpose
- [ ] Safety warnings on destructive tasks
- [ ] Non-obvious parameters explained
- [ ] Documentation is scannable, not verbose
