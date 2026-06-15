# Media (arr) Stack Migration — master (K8s) → rebuild (Docker Compose)

This is the **durable tracking doc** for porting the media stack from the
Kubernetes/Helm setup on `master` to the Docker Compose + Ansible layered
architecture on `rebuild`. It records the decisions, per-service status, and the
repeatable porting recipe so the migration survives across sessions. Per-service
operational notes live in each role's `README.md`; the master
`docs/media-stack-complete-guide.md` is K8s reference only and is **not** ported
wholesale.

## Why this migration

The stack (qBittorrent+VPN, Prowlarr, Radarr, Sonarr, Jellyfin, Jellyseerr) ran
on `master` as `bjw-s/app-template` Helm releases on a K3s cluster. `rebuild`
replaces that with per-service Ansible roles deploying Docker Compose stacks
(the Seafile pattern). So every service is a **port + architecture conversion**,
done **one service at a time, validating each before the next**, fundamental
services first.

## Topology (decided 2026-06)

On `master` the stack ran on **beelink** (Intel N150 + local `/mnt/storage/media`).
On `rebuild`, **beelink is now offsite backup only and `valen` replaces it** as
the media host. valen has an equivalent Intel CPU/iGPU, the 12 TB pool, and sits
on the home LAN. Therefore:

- **Compute + storage + GPU transcoding all co-locate on valen.**
- Media data is **local** → containers use **bind mounts** to `/mnt/storage/media`,
  *not* NFS volumes (the Seafile NFS-volume detail does **not** apply here).
- Hardlinks between `/data/torrents` and `/data/media` work natively because it is
  one local filesystem — this is what makes seed-while-streaming with no data
  duplication possible.
- valen's HDD spins down after 20 min idle (`disk-spindown.yml`); active media
  services keep it spinning during use — expected for a media host.

## Storage layout (on valen's pool, `/mnt/storage/media` → `/data` in every app)

```
/mnt/storage/media/                 (media_data_root, owned 8000:8000, mode 2775)
├── torrents/
│   ├── incomplete/                 qBittorrent in-progress
│   ├── movies/                     qBittorrent category → Radarr import source
│   └── tv/                         qBittorrent category → Sonarr import source
└── media/
    ├── movies/                     Radarr root folder (hardlinked from torrents)
    └── tv/                         Sonarr root folder (hardlinked from torrents)
```

Created by `playbooks/media-storage.yml`. UID/GID 8000 is the pool media account
(`storage_media_uid`/`storage_media_gid`), used as `PUID`/`PGID` in every app.

## Auth model

- **Native OIDC** for apps that support it: Jellyseerr (and Jellyfin where
  practical). Pattern = Grafana's `auth.generic_oauth` block in
  `group_vars/monitoring/main.yml`.
- **Forward-auth** for the no-native-OIDC apps (qBittorrent, Prowlarr, Radarr,
  Sonarr): a single reusable Traefik `forwardAuth` middleware on valen's Traefik
  pointing at Authentik's embedded outpost. See "Forward-auth setup" below.

### Forward-auth setup (one-time, Phase 0)

Ansible side (`playbooks/media-forward-auth.yml`): drops
`/etc/traefik/conf.d/forward-auth.yml` on valen defining the middleware
`authentik-forward-auth`. Each protected router references it as
`authentik-forward-auth@file`.

Authentik side (manual UI — `authentik-app` skill), **domain-level** forward auth
so one provider covers every `*.jardoole.xyz` app:

1. **Providers → Create → Proxy Provider**
   - Name: `media-forward-auth`
   - Authorization flow: `default-provider-authorization-implicit-consent`
   - Forward auth mode: **Forward auth (domain level)**
   - External host: `https://auth.jardoole.xyz`
   - Cookie domain: `jardoole.xyz`
   - Token validity / signing key: set the **authentik Self-signed Certificate**
     (without a signing key the OIDC/outpost endpoints 404).
2. **Applications → Create** one app per service (e.g. `qBittorrent`, slug
   `qbittorrent`) bound to the provider above, OR a single catch-all app — but
   per-app gives per-service access policies. Bind an **API-bypass policy** (see
   next) where app-to-app API calls must skip auth.
3. **Outposts → embedded outpost → edit → add the provider(s)** so the embedded
   outpost (on the Authentik host, pi-cm5-1) serves them.
4. **API bypass** for *arr↔*arr calls: add an **Expression Policy** on the
   application's authorization binding that returns `True` (allow without auth)
   when the request path starts with `/api`:
   ```python
   return ak_is_group_member(request.user, name="media") or \
          request.context.get("http_request", {}).get("path", "").startswith("/api")
   ```
   (Adjust to your access model; the key part is allowing `/api` so Prowlarr ↔
   Radarr/Sonarr and download-client calls work.)

The middleware `forwardAuth.address` targets `https://auth.jardoole.xyz/outpost.goauthentik.io/auth/traefik`,
which valen reaches over the network (DNS → the Authentik host's Traefik →
loopback to Authentik:9000). No change to Authentik's loopback binding is needed.

> Troubleshooting: if the redirect loop or `/outpost.goauthentik.io/` 404s on an
> app domain, add a Traefik router on valen forwarding `PathPrefix(/outpost.goauthentik.io/)`
> for that host to the same upstream — domain-level usually avoids this, but
> note it here if hit.

## Repeatable porting recipe (per service `<svc>`)

Template = `playbooks/seafile.yml` + `roles/seafile/`. For each service:

1. `roles/<svc>/` — `tasks/main.yml` (create stack dir → template
   `docker-compose.yml.j2` + `env.j2` → `community.docker.docker_compose_v2`),
   `templates/`, `defaults/main.yml`, `README.md`.
2. `group_vars/<svc>/main.yml` (image pin, port, dirs, hostname, integrations) +
   `vault.yml` (secrets, `vault_` prefix, created via `/vault`).
3. `playbooks/<svc>.yml` — deploy the role + drop
   `playbooks/templates/traefik-<svc>.yml.j2` → `/etc/traefik/conf.d/<svc>.yml`.
   *arr routers reference `authentik-forward-auth@file`.
4. `[<svc>]` group in `hosts.ini` → `valen`.
5. Authentik wiring (forward-auth app, or native OIDC).
6. `import_playbook` line in `playbooks/applications.yml`.
7. **Config backup** (any service with hand-tuned `/config`): add a
   `config-backup` restic sidecar + a `backups:` manifest in `group_vars/<svc>`
   (model on qBittorrent), and a Garage bucket/key-provisioning play at the top of
   `playbooks/<svc>.yml`. The settings are then captured once and restorable via
   `make verify-backups`/`make restore-backups SERVICE=<svc>`.
8. **Validate the gate**, update the status table below, then move on.

Compose conventions: data is a **bind mount** (`{{ media_data_root }}:/data`),
config a local bind (`/opt/<svc>/config:/config`); `PUID/PGID=8000`; ports bind
`127.0.0.1` only; `json-file` logging with size caps; non-secrets via Jinja from
`group_vars`, secrets via `${VAR}` from `.env` templated from vault.

## Service status

| # | Service | Image (pin) | SSO | Status | Notes |
|---|---------|-------------|-----|--------|-------|
| — | Phase 0 — valen Docker+ingress | — | — | ☐ | hosts.ini, docker.yml, traefik.yml on valen |
| — | Phase 0 — GPU drivers | — | — | ☐ | `playbooks/gpu-drivers.yml`; verify `/dev/dri/renderD128` |
| — | Phase 0 — media storage | — | — | ☐ | `playbooks/media-storage.yml` |
| — | Phase 0 — forward-auth infra | — | — | ☐ | middleware + Authentik provider |
| 1 | qBittorrent + gluetun + port-manager | `qbittorrent:5.1.4` / `gluetun:v3.41.0` / `port-manager:1.3` | forward-auth | ☐ | VPN egress + port-forward + hardlink-ready `/data`; `/config` restic-backed up to Garage |
| 2 | Prowlarr | `prowlarr:2.1.5` | forward-auth (`/api` bypass) | ☐ | indexer source; `/config` restic-backed up to Garage |
| 3 | Radarr | `radarr:5.3.6` | forward-auth (`/api` bypass) | ☐ | wire Prowlarr + qBittorrent; hardlinks on |
| 4 | Sonarr | `sonarr:4.0.2` | forward-auth (`/api` bypass) | ☐ | same as Radarr, TV |
| 5 | Jellyfin | `jellyfin:10.11.2` | native/forward-auth | ☐ | `/dev/dri` + `group_add`; QSV transcode |
| 6 | Jellyseerr | `jellyseerr:2.7.3` | native OIDC | ☐ | wire Jellyfin + Radarr + Sonarr |

Order is fundamental → up the stack. **Do not advance until the current gate passes.**

## Validation gates (summary)

- **qBittorrent:** VPN egress IP ≠ home IP (`curl` from inside the netns); a
  forwarded port appears and qBittorrent's listen port updates; WebUI via
  `qbittorrent.jardoole.xyz` behind Authentik; categories map to `/data/torrents/*`.
- **Prowlarr:** UI via SSO; a test indexer added; API reachable on host.
- **Radarr/Sonarr:** grab → download in qBittorrent → import via hardlink
  (`ls -li` shows identical inodes in `/data/torrents` and `/data/media`).
- **Jellyfin:** `vainfo` in-container lists QSV profiles; transcode shows GPU use
  (`intel_gpu_top`); playback works.
- **Jellyseerr:** SSO login; request → Radarr/Sonarr → appears in Jellyfin.
- **End-to-end:** request in Jellyseerr → automation → VPN download → hardlink →
  GPU-transcoded playback, every UI behind Authentik.

## Open items

- Confirm valen exposes `*.jardoole.xyz` externally the same way pi-cm5-2/Seafile
  does (DNS + any port-forward/tunnel).
- Confirm valen's iGPU presents `/dev/dri/renderD128` before relying on HW transcode.
- Decide Jellyfin auth (native plugin vs forward-auth) at Phase 5.
- Confirm ProtonVPN `+pmp` credentials are valid for NAT-PMP port forwarding.

## Execution constraints (per CLAUDE.md)

No playbook/`make` runs except `make precommit`; only read-only
`uv run ansible … -a` checks for validation; secrets via `/vault`; vault files are
never read.
