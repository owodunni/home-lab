# CLAUDE.md

Home lab automation using Ansible to provision servers.

## Playbook Architecture: Layers

Playbooks are organized into three flat tiers under `playbooks/` (plus the
top-level `site.yml`). No subfolders.

1. **Function playbooks** — one concern each (e.g. `upgrade.yml`,
   `pi-base-config.yml`, `unattended-upgrades.yml`). They set their own
   `hosts`/`become` and are self-contained: they know nothing about
   orchestration and run standalone.
2. **Layer playbooks** — group related function playbooks into an ordered
   phase. Pure `import_playbook` aggregators; **no logic of their own**.
3. **`site.yml`** (repo root) — imports the layers in sequence to provision a
   fresh host end to end.

Each tier stays independently runnable: a single function, a whole layer, or
the entire site.

### Current layers (run in this order)

| Layer | Purpose | Function playbooks | Hosts |
|---|---|---|---|
| **system** | Base OS state: apply all package updates, then Pi CM5 firmware/hardware/power settings. | `upgrade.yml`, `pi-base-config.yml` | `all` / `pi_cm5` |
| **networking** | WireGuard peers for cross-site connectivity. Tunnels offsite hosts into the home LAN; skips hosts until their UniFi peer values are filled in. | `wireguard.yml` | `wireguard` |
| **storage** | Encrypted drives, MergerFS pool, SnapRAID parity. Only runs on `[storage]` group hosts. | `disk-encrypt.yml`, `snapraid-mergerfs.yml` | `storage` |
| **security** | Hardening: automatic security updates (firewall, SSH hardening to come). | `unattended-upgrades.yml` | `all` |

**Order matters:** `system` first (patched OS before anything else), then
`networking` (establish cross-site reachability so later layers can manage
offsite hosts), then `storage` (functional setup before security rules can
interfere with package downloads and drive operations), then `security` last.
Hardening is the most likely step to lock an operator out, so it always runs
after the host is fully configured.

### Working with layers

- **New single concern** → create a flat function playbook in `playbooks/`,
  then add one `import_playbook` line to the layer it belongs to.
- **New phase** → create a layer playbook and add it to `site.yml` in the right
  position. Document the ordering rationale (see below).
- Keep layer and `site.yml` files logic-free — they only compose. Put real
  tasks in roles or function playbooks.
- `import_playbook` entries need a `name:` (ansible-lint `name[play]`).
- Targets: `make system`, `make security`, `make site`, plus per-function
  targets (`make upgrade`, etc.).

## Documenting Config Changes

**MANDATORY**: Every config change — especially during debug sessions — MUST include:

1. **What** is being changed
2. **Why** it is needed (root cause, not symptom)
3. **What issue** it resolves

Apply this in `group_vars`, `values.yml`, playbooks, and any other config file. A future reader must be able to understand why a non-obvious value exists without needing context from the conversation.

## Git Commit Guidelines

**MANDATORY**: Run `/commit` before each commit.

**Pre-commit workflow:**

1. Stage files: `git add .`
2. Commit — pre-commit hooks run automatically
3. If hooks fail, fix the reported issues
4. Stage fixes: `git add .`
5. Commit again with proper message format

Run `make precommit` to trigger hooks manually without committing.

**IMPORTANT:** Always commit after completing changes. Do not leave work uncommitted at the end of a task.

## Ansible Vault

**CRITICAL**: All secrets MUST be encrypted with ansible-vault.

- Use `vault_` prefix for all encrypted variables
- Run `/vault` for the complete guide

**ABSOLUTE PROHIBITION**: Never read, cat, view, print, or inspect vault files
in any way under any circumstances. This includes `host_vars/*/vault.yml`,
`group_vars/*/vault.yml`, and any file beginning with `$ANSIBLE_VAULT`.
No exceptions.

## CRITICAL: Ansible Execution Restrictions

**NEVER run playbooks or make tasks except `make precommit`** - they consume tokens rapidly.

**Approved commands only:**

- `make precommit` - Static analysis and linting
- `uv run ansible [host] -a "[read-only command]"` - Single host **read-only** checks (e.g., `ls`, `stat`, `cat`, `df`)
