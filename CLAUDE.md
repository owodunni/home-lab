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
| **system** | Base OS state and per-host hardware enablement: apply all package updates, then Pi CM5 firmware/hardware/power settings and Intel GPU drivers (QuickSync/VA-API) on the media host. GPU drivers live here, not with the media apps, because they are host hardware state present whatever runs on top. | `upgrade.yml`, `pi-base-config.yml`, `gpu-drivers.yml` | `all` / `pi_cm5` / `media` |
| **networking** | WireGuard peers for cross-site connectivity. Tunnels offsite hosts into the home LAN; skips hosts until their UniFi peer values are filled in. | `wireguard.yml` | `wireguard` |
| **storage** | Encrypted drives, MergerFS pool, SnapRAID parity, the media data tree on the pool, NFS export of the pool, HDD spin-down. The media tree lives here (storage layout, owned by the media account) rather than with the media apps that bind-mount it. Runs on `[storage]`; the NFS client step runs on `[nfs_client]` (the Docker fleet). | `disk-encrypt.yml`, `snapraid-mergerfs.yml`, `media-storage.yml`, `nfs.yml`, `disk-spindown.yml` | `storage` / `media` / `nfs_server` / `nfs_client` |
| ingress | Traefik reverse proxy with ACME wildcard certificates via Cloudflare DNS-01. | `traefik.yml` | `ingress` |
| **service-infra** | Foundational infrastructure that application services depend on: the Docker runtime, and Garage S3 object storage (a shared storage backend — the target for Authentik's DB backups, and available to future services). Garage lives here, below auth, because other services consume it. | `docker.yml`, `garage.yml` | `services` / `garage` |
| **auth** | Identity provider (Authentik SSO/OIDC). Must be live before any service configures OIDC integration against it. Provisions its backup bucket/key on Garage, so `service-infra` runs first. | `authentik.yml` | `authentik` |
| **applications** | End-user app services that sit on the full platform (ingress + Docker + NFS, and auth for SSO). Nextcloud file sync/share — compute on a Pi, bulk file data on valen's pool over an NFS host mount, behind a co-located Traefik; its Postgres DB and its NFS file data are both backed up offsite to Garage (pg_dump→restic and restic), and it uses native Authentik OIDC (forward-auth would break the sync/WebDAV clients). Plus the **media (arr) stack** on valen (compute + storage + Intel iGPU transcoding co-located, local bind mounts): the shared foundations (`media-network.yml` cross-stack Docker network, then `media-forward-auth.yml` SSO middleware) then services in dependency order — qBittorrent+VPN, Prowlarr, Radarr, Sonarr, Jellyfin (QuickSync), Jellyseerr — see `docs/media-stack-migration.md`. The *arr apps sit behind forward-auth; Jellyfin and Jellyseerr use their own auth (forward-auth breaks Jellyfin native clients). Its hardware (GPU drivers) and storage layout (media tree) foundations live in the `system` and `storage` layers respectively. | `nextcloud.yml`, `media-network.yml`, `media-forward-auth.yml`, `qbittorrent.yml`, `prowlarr.yml`, `radarr.yml`, `sonarr.yml`, `jellyfin.yml`, `jellyseerr.yml` | `nextcloud` / `media` / `qbittorrent` / `prowlarr` / `radarr` / `sonarr` / `jellyfin` / `jellyseerr` |
| **monitoring** | Observability stack: node_exporter on every host; smartctl_exporter (SMART drive health) on `[storage]`; Prometheus, Alertmanager, and Grafana on `[monitoring]`. Alert rules cover host and drive faults (failed SMART status, reallocated/pending sectors, temperature, NVMe wearout) and route to email via Alertmanager. Grafana exposed at `grafana.jardoole.xyz` via Traefik. Runs after `applications` so every service it scrapes already exists. | `node-exporter.yml`, `smartctl-exporter.yml`, `prometheus.yml`, `grafana.yml` | `all` / `storage` / `monitoring` |
| **security** | Hardening: automatic security updates (firewall, SSH hardening to come). | `unattended-upgrades.yml` | `all` |

**Order matters:** `system` first (patched OS and host hardware before anything
else), then `networking` (establish cross-site reachability so later layers can
manage offsite hosts), then `storage` (functional setup before security rules
can interfere with package downloads and drive operations), then `ingress`
(Traefik must be running before any service routing configs land), then
`service-infra` (the Docker runtime and Garage S3 — both are dependencies of the
layers above: Docker runs the app containers, and Garage is the backend
Authentik backs its database up to, so it must exist before `auth`), then `auth`
(Authentik provisions its backup bucket/key on the now-live Garage, then deploys
with its restic backup sidecars), then `applications` (end-user services that
depend on every platform layer below them — ingress, Docker, NFS, and a live
Authentik for any SSO), then `monitoring` (it scrapes the services the
`applications` layer deploys, so it runs after them; Traefik must also be running
for the Grafana routing config and Authentik live for Grafana SSO), then
`security` last. Hardening is the most likely step to lock an operator out, so
it always runs after the host is fully configured.

A dependency belongs in a layer *below* the things that consume it. That is why
Garage sits in `service-infra` (other services use it as a backend) rather than
in a leaf services layer, and why the media stack's GPU drivers and data tree
live in `system` and `storage` rather than alongside the media apps. The
`applications` layer holds only the actual services (and their auth middleware):
it is where a service that consumes OIDC belongs, sequenced after `auth` and
before `monitoring`.

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
`defaults/main.yml` or `vars/main.yml` and no inline `vars:`/`default()`
fallbacks — every value it consumes is defined once in `group_vars/<service>/`.
Do not split a service's config across both places: a default in the role plus an
override in `group_vars` is the duplication this convention exists to prevent
(two sources of truth, and the role default silently wins when the `group_vars`
entry is renamed). If the role needs a structural constant that is not host/env
config (e.g. an `argv` command prefix shared across tasks), still define it in
`group_vars/<service>/main.yml` so there is one home for everything the service
references. The **only** role carrying `defaults/` is `pi_cm5_config`, and that
is deliberate: it is a generic, parameterized hardware role (geerlingguy-style)
whose defaults are meant to be overridden per group/host, not a service.

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

Backups are codified as two generic, manifest-driven playbooks that work for
**any** service — there are no service-specific backup playbooks. Every backup
is a **restic** snapshot (a database is a `pg_dump` captured in restic), so
databases and file volumes share one grandfather-father-son retention policy and
the same restore-any-snapshot behaviour.

```bash
make verify-backups  SERVICE=authentik   # non-destructive: exist + fresh? + list every restore point
make restore-backups SERVICE=authentik   # DESTRUCTIVE (typed-confirm): restore each backup's latest snapshot
```

**Restoring an older (non-latest) snapshot** — `restore-backups` takes an
optional `TARGETS` map of `name=snapshot-id` pairs:

```bash
make restore-backups SERVICE=authentik TARGETS='postgres=ab12cd34,volumes=ef56ab78'
```

- The **name** (`postgres`, `volumes`, …) is the entry's `name:` in the
  service's `backups:` manifest — *not* a hostname or compose service.
- The **snapshot id** is a restic short-ID from `make verify-backups` (or
  `restic snapshots` on the host).
- Any backup you omit — or omitting `TARGETS` entirely — restores its **latest**
  snapshot. The repos are independent (no single cross-backup point-in-time);
  pick the nearest snapshot in each.

**Run `/backups`** for the full guide: the manifest schema, how verify/restore
dispatch per engine, how a restore executes, and how to add a new backup engine.

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
