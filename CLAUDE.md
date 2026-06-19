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
| **system** | Base OS + per-host hardware: package updates, then Pi CM5 firmware/power and Intel GPU drivers (QuickSync/VA-API) on the media host. | `upgrade.yml`, `pi-base-config.yml`, `gpu-drivers.yml` | `all` / `pi_cm5` / `media` |
| **networking** | WireGuard peers tunneling offsite hosts into the home LAN. Skips hosts until their UniFi peer values are filled in. | `wireguard.yml` | `wireguard` |
| **storage** | Encrypted drives, MergerFS pool, SnapRAID parity, the media data tree, NFS export of the pool, HDD spin-down. Exports on `[storage]`; NFS client step on `[nfs_client]` (the Docker fleet). | `disk-encrypt.yml`, `snapraid-mergerfs.yml`, `media-storage.yml`, `nfs.yml`, `disk-spindown.yml` | `storage` / `media` / `nfs_server` / `nfs_client` |
| **ingress** | Traefik reverse proxy with ACME wildcard certificates via Cloudflare DNS-01. | `traefik.yml` | `ingress` |
| **service-infra** | Docker runtime + Garage S3 object storage — a shared backend other services consume (e.g. Authentik DB backups). | `docker.yml`, `garage.yml` | `services` / `garage` |
| **auth** | Authentik SSO/OIDC identity provider. Backs up to Garage. | `authentik.yml` | `authentik` |
| **applications** | End-user services on the full platform. Nextcloud, Vaultwarden, and the media (arr) stack — see [Application notes](#application-notes) below. | `nextcloud.yml`, `vaultwarden.yml`, `media-network.yml`, `media-forward-auth.yml`, `qbittorrent.yml`, `prowlarr.yml`, `radarr.yml`, `sonarr.yml`, `jellyfin.yml`, `jellyseerr.yml` | `nextcloud` / `vaultwarden` / `media` / `qbittorrent` / `prowlarr` / `radarr` / `sonarr` / `jellyfin` / `jellyseerr` |
| **monitoring** | node_exporter everywhere, smartctl_exporter on `[storage]`, Prometheus + Alertmanager + Grafana on `[monitoring]`. Alert rules for host/drive faults route to email; Grafana at `grafana.jardoole.xyz`. | `node-exporter.yml`, `smartctl-exporter.yml`, `prometheus.yml`, `grafana.yml` | `all` / `storage` / `monitoring` |
| **security** | Hardening: automatic security updates (firewall, SSH hardening to come). | `unattended-upgrades.yml` | `all` |

**Ordering principle:** a dependency belongs in a layer *below* the things that
consume it, and hardening runs last (it is the most likely step to lock an
operator out). Concretely: `system` (patched OS + hardware first) → `networking`
(reachability to offsite hosts) → `storage` (before security rules interfere with
package/drive operations) → `ingress` (Traefik up before any routing config) →
`service-infra` (Docker runs the app containers; Garage is the backend `auth`
backs up to) → `auth` (live before any service configures OIDC) → `applications`
(depend on every layer below — ingress, Docker, NFS, SSO) → `monitoring` (scrapes
the services `applications` deploys) → `security`.

This is also why the media stack's GPU drivers and data tree live in `system` and
`storage` rather than alongside the media apps: they are host hardware and storage
state, consumed by the apps above.

#### Application notes

- **Nextcloud** — compute on a Pi, bulk file data on valen's pool over an NFS host
  mount, behind a co-located Traefik. Postgres DB and NFS file data both backed up
  offsite to Garage (pg_dump→restic and restic). Uses native Authentik OIDC —
  forward-auth would break the sync/WebDAV clients.
- **Vaultwarden** — password manager co-located with Nextcloud on the same Pi
  (Postgres backend + data dir all local), behind the co-located Traefik. Postgres
  DB and data dir both backed up offsite to Garage (pg_dump→restic and restic).
  Uses native Authentik OIDC SSO — forward-auth would break the Bitwarden clients.
- **Media (arr) stack** — on valen (compute + storage + Intel iGPU transcoding
  co-located, local bind mounts). Foundations first (`media-network.yml` cross-stack
  Docker network, then `media-forward-auth.yml` SSO middleware), then services in
  dependency order: qBittorrent+VPN, Prowlarr, Radarr, Sonarr, Jellyfin (QuickSync),
  Jellyseerr. The *arr apps sit behind forward-auth; Jellyfin and Jellyseerr use
  their own auth (forward-auth breaks Jellyfin native clients). See
  `docs/media-stack-migration.md`.

### Service host targeting

Each service has a dedicated inventory group in `hosts.ini`. Function playbooks
target the group name — never a hostname directly, and never an infrastructure
tier group.

```ini
# hosts.ini — to move Authentik, change this one line
[authentik]
pi-cm5-1
```

```yaml
# authentik.yml — never changes when the service moves
hosts: authentik
```

Service variables live in `group_vars/<service>/`:

- `main.yml` — non-secret config (version pins, ports, directories)
- `vault.yml` — encrypted secrets (passwords, API tokens)

This means all variables travel with the service definition. Migrating a service
to a new host is a single-line `hosts.ini` change with no playbook edits.

**Variables live in `group_vars/<service>/`, not in the role.** A service role
(`roles/nextcloud`, `roles/authentik`, the *arr roles, …) holds **no**
`defaults/main.yml`, `vars/main.yml`, or inline `vars:`/`default()` fallbacks —
every value it consumes, including structural constants like a shared `argv`
prefix, is defined once in `group_vars/<service>/`. Splitting config across both
places is the exact duplication this prevents: two sources of truth, with the
role default silently winning when the `group_vars` entry is renamed. The **only**
role carrying `defaults/` is `pi_cm5_config` — deliberately, as a generic
parameterized hardware role (geerlingguy-style) meant to be overridden per
group/host, not a service.

Infrastructure groups (`[ingress]`, `[services]`, `[monitoring]`) describe *what
infrastructure runs where* and are targets for infrastructure playbooks only
(e.g. `docker.yml` uses `hosts: services` because Docker goes on every host in
that group). Never use infrastructure groups as service targets.

### Working with layers

- **New single concern** → create a flat function playbook in `playbooks/`,
  then add one `import_playbook` line to the layer it belongs to.
- **New phase** → create a layer playbook and add it to `site.yml` in the right
  position. Document the ordering rationale (see below).
- Keep layer and `site.yml` files logic-free — they only compose. Put real
  tasks in roles or function playbooks.
- `import_playbook` entries need a `name:` (ansible-lint `name[play]`).
- Targets: one per layer (`make system`, `make storage`, `make service-infra`,
  …, `make security`) plus `make site`. There are **no** per-function targets at
  layer granularity. The one exception is `make app service=<name>`, which
  deploys a single application service whose playbook filename, inventory group,
  and `group_vars/` dir all share `<name>` (e.g. `make app service=qbittorrent`
  runs `playbooks/qbittorrent.yml`). For any other one-off function playbook,
  invoke it directly: `uv run ansible-playbook playbooks/<function>.yml`.

## Backups: verify & restore

Two generic, manifest-driven playbooks back up **any** service — no
service-specific backup playbooks. Every backup is a **restic** snapshot (a
database is a `pg_dump` captured in restic), so DBs and file volumes share one
grandfather-father-son retention policy and the same restore-any-snapshot path.

```bash
make verify-backups  SERVICE=authentik   # non-destructive: exist + fresh? + list restore points
make restore-backups SERVICE=authentik   # DESTRUCTIVE (typed-confirm): restore each backup's latest snapshot
```

To restore an **older** snapshot, pass a `TARGETS` map of `name=snapshot-id`
pairs (omitted backups restore their latest):

```bash
make restore-backups SERVICE=authentik TARGETS='postgres=ab12cd34,volumes=ef56ab78'
```

The **name** is the entry's `name:` in the service's `backups:` manifest (not a
host or compose service); the **id** is a restic short-ID from `make
verify-backups`. Repos are independent — pick the nearest snapshot in each.

**Run `/backups`** for the full guide: manifest schema, per-engine verify/restore
dispatch, how a restore executes, and adding a new backup engine.

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
