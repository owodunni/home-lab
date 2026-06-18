# Media (arr) Stack Migration — master (K8s) → rebuild (Docker Compose)

This is the **durable tracking doc** for porting the media stack from the
Kubernetes/Helm setup on `master` to the Docker Compose + Ansible layered
architecture on `rebuild`. It records the decisions, per-service status, and the
repeatable porting recipe so the migration survives across sessions. Per-service
operational notes live in each role's `README.md`, and the day-to-day operational
overview (data flow, end-to-end validation, troubleshooting, maintenance) lives in
[`docs/media-stack-complete-guide.md`](media-stack-complete-guide.md), ported to
this Docker Compose stack — this doc keeps the migration decisions, auth setup,
and status.

## Why this migration

The stack (qBittorrent+VPN, Prowlarr, Radarr, Sonarr, Jellyfin, Jellyseerr) ran
on `master` as `bjw-s/app-template` Helm releases on a K3s cluster. `rebuild`
replaces that with per-service Ansible roles deploying Docker Compose stacks
(the same per-service Compose pattern Nextcloud uses). So every service is a **port + architecture conversion**,
done **one service at a time, validating each before the next**, fundamental
services first.

## Topology (decided 2026-06)

On `master` the stack ran on **beelink** (Intel N150 + local `/mnt/storage/media`).
On `rebuild`, **beelink is now offsite backup only and `valen` replaces it** as
the media host. valen has an equivalent Intel CPU/iGPU, the 12 TB pool, and sits
on the home LAN. Therefore:

- **Compute + storage + GPU transcoding all co-locate on valen.**
- Media data is **local** → containers use **bind mounts** to `/mnt/storage/media`,
  *not* NFS (the Nextcloud NFS-mount detail does **not** apply here).
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

Three distinct mechanisms — the right one per app, **not** forward-auth for
everything:

- **Forward-auth** (Traefik `forwardAuth` middleware → Authentik embedded
  outpost) for the no-native-auth apps: **qBittorrent, Prowlarr, Radarr,
  Sonarr**. One reusable middleware on valen's Traefik. See "Forward-auth setup".
- **In-app OIDC plugin** for **Jellyfin**: the [9p4 `jellyfin-plugin-sso`](https://github.com/9p4/jellyfin-plugin-sso)
  authenticates *inside* Jellyfin against an Authentik OAuth2/OpenID provider.
  Forward-auth is deliberately **not** used here — its browser redirect breaks
  Jellyfin's native clients (Android/iOS/TV/Kodi). See "Jellyfin SSO setup".
- **Native OIDC** for **Jellyseerr**: built-in OpenID Connect, configured in the
  Jellyseerr UI against an Authentik OAuth2/OpenID provider (Grafana's
  `auth.generic_oauth` block in `group_vars/monitoring/main.yml` is the
  conceptual pattern; Jellyseerr's is in-app, not Ansible-managed).

### Authentik groups & access model

**Two groups cover the whole stack** (create both in Authentik → Directory →
Groups). Access is **deny-by-default**: every Authentik application binds a group
policy, so a logged-in user in *neither* group gets nothing.

- **`media-admins`** — operators. Full access to everything: the four management
  UIs (qBittorrent, Prowlarr, Radarr, Sonarr) **and** admin rights in Jellyfin
  and Jellyseerr. This is the single admin group the *arr apps gate on.
- **`media-users`** — consumers. Access to **Jellyfin and Jellyseerr only**
  (watch media, make requests). No access to any *arr/download UI.

| App | `media-admins` | `media-users` | How it's enforced |
|-----|:--:|:--:|---|
| qBittorrent | ✅ | ❌ | forward-auth app bound to `media-admins` |
| Prowlarr | ✅ | ❌ | forward-auth, `media-admins` (+ `/api` bypass) |
| Radarr | ✅ | ❌ | forward-auth, `media-admins` (+ `/api` bypass) |
| Sonarr | ✅ | ❌ | forward-auth, `media-admins` (+ `/api` bypass) |
| Jellyfin | ✅ admin | ✅ user | SSO plugin: **Roles** = both groups, **Admin Roles** = `media-admins` |
| Jellyseerr | ✅ admin | ✅ user | native OIDC: app bound to both groups; admins promoted by group |

So the *arr apps reference exactly one group (`media-admins`) and deny everyone
else; only Jellyfin and Jellyseerr use the two-tier admin/user split.

### Forward-auth setup (one-time, Phase 0)

Ansible side, two foundation playbooks run first in the applications-layer media
sequence:

- `playbooks/media-network.yml` creates the shared **`media` Docker network**
  (`group_vars/media` → `media_docker_*`) that every stack joins as external — so
  the *arr reach qBittorrent at `http://gluetun:8080` and each other by container
  name, off the public forward-auth'd URL, and deploy order between stacks does
  not matter.
- `playbooks/media-forward-auth.yml` drops `/etc/traefik/conf.d/forward-auth.yml`
  on valen defining the middleware `authentik-forward-auth`. Each protected
  router references it as `authentik-forward-auth@file`.

Authentik side (manual UI — `authentik-app` skill): **one proxy provider +
application per service**, each in **domain-level** forward-auth mode. There is
no single shared provider — per-app providers are what let each service carry its
own access policy.

1. **Providers → Create → Proxy Provider** — one per service (`qbittorrent`,
   `prowlarr`, `radarr`, `sonarr`):
   - Name: `<service>-forward-auth` (e.g. `radarr-forward-auth`)
   - Authorization flow: `default-provider-authorization-implicit-consent`
   - Forward auth mode: **Forward auth (domain level)**
   - External host: `https://auth.jardoole.xyz`
   - Cookie domain: `jardoole.xyz` — **critical, easy to get wrong.** The proxy
     session cookie must be scoped to the parent domain so it is sent to every
     `*.jardoole.xyz` app. If this is blank or set to `auth.jardoole.xyz`, an
     already-signed-in user is treated as unauthenticated at each app, bounced to
     Authentik, and (their core session being live) dumped on the **My
     Applications** dashboard instead of landing in the app — see Troubleshooting.
   - Token validity / signing key: set the **authentik Self-signed Certificate**
     (without a signing key the OIDC/outpost endpoints 404).
2. **Applications → Create** one app per *arr service (`qBittorrent`/`qbittorrent`,
   `Prowlarr`/`prowlarr`, `Radarr`/`radarr`, `Sonarr`/`sonarr`), each bound to
   **its own** provider from step 1. Per-app providers (not one catch-all) are
   what let each carry its own access policy. On each, bind the **admin-gate +
   API-bypass Expression Policy** below.
3. **Outposts → embedded outpost → edit → add the provider(s)** so the embedded
   outpost (on the Authentik host, pi-cm5-1) serves them.
4. **Admin gate + API bypass** — one **Expression Policy** bound to each *arr
   application's authorization. It allows only `media-admins` members (so the
   *arr UIs are admin-only and **deny-by-default** for everyone else), while
   still letting unauthenticated `/api` calls through for app-to-app traffic
   (Prowlarr ↔ Radarr/Sonarr, download-client calls):
   ```python
   return ak_is_group_member(request.user, name="media-admins") or \
          request.context.get("http_request", {}).get("path", "").startswith("/api")
   ```
   These four apps reference **only** `media-admins` — `media-users` deliberately
   has no path to them.

The middleware `forwardAuth.address` targets `https://auth.jardoole.xyz/outpost.goauthentik.io/auth/traefik`,
which valen reaches over the network (DNS → the Authentik host's Traefik →
loopback to Authentik:9000). No change to Authentik's loopback binding is needed.

> Troubleshooting:
> - **Signed in, but landed on the Authentik "My Applications" dashboard and had
>   to click the app to proceed** → two independent causes, both needed:
>   1. The Authentik host's Traefik (pi-cm5-1) **scrubs the `X-Forwarded-Host`**
>      valen sends on the forward-auth check, because valen isn't a trusted
>      forwarder. The outpost then builds the post-login redirect (`rd`) for
>      `auth.jardoole.xyz` and dumps the user on the dashboard. Fixed by
>      `traefik_forwarded_trusted_ips` (trusts the LAN on the `websecure`
>      entrypoint so the real origin host survives the valen→pi-cm5-1 hop) —
>      redeploy Traefik on pi-cm5-1 after changing it. **This was the actual
>      blocker.**
>   2. The provider's **Cookie domain** must be `jardoole.xyz` so the shared
>      session cookie reaches each app subdomain. A prerequisite, not sufficient
>      on its own.
> - **Authentik-branded 404 (`Not Found`) instead of a login** → the provider is
>   not assigned to the **embedded outpost** (Outposts → embedded outpost → edit →
>   add it). The outpost has no provider matching the request, so it 404s.
> - **Redirect loop or `/outpost.goauthentik.io/` 404 on an app domain** → add a
>   Traefik router on valen forwarding `PathPrefix(/outpost.goauthentik.io/)` for
>   that host to the same upstream. Domain-level usually avoids this (its browser
>   endpoints live on `auth.jardoole.xyz`), but note it here if hit.

### Jellyfin SSO setup (in-app OIDC plugin)

Jellyfin SSO is the [9p4 `jellyfin-plugin-sso`](https://github.com/9p4/jellyfin-plugin-sso)
talking OIDC to Authentik — a "Sign in with SSO" button on Jellyfin's own login
page that maps Authentik users/groups to Jellyfin accounts. Native apps keep
using normal Jellyfin logins; the browser uses SSO. All manual (Authentik UI +
Jellyfin UI); nothing here is Ansible-managed. Based on the
[Authentik Jellyfin integration guide](https://docs.goauthentik.io/integrations/services/jellyfin/).

**Naming gotcha:** the provider name suffix in Authentik's redirect URI, the
plugin's "OID Provider name", and the `/sso/OID/...redirect/<name>` /
`/sso/OID/start/<name>` paths must **all** be the identical string. This guide
uses `authentik` for that name throughout.

**1. Authentik — create an OAuth2/OpenID Provider** (Providers → Create →
OAuth2/OpenID Provider):

- Name: `jellyfin`
- Authorization flow: `default-provider-authorization-implicit-consent` (or
  explicit, your choice)
- Client type: **Confidential**
- Redirect URI — mode **Strict**, value:
  `https://jellyfin.jardoole.xyz/sso/OID/redirect/authentik`
- Signing key: the **authentik Self-signed Certificate** (without it the
  `.well-known`/JWKS endpoints don't serve — same caveat as the forward-auth
  provider).
- Scopes: leave the defaults (`openid`, `email`, `profile`). Authentik's
  `profile` scope emits a `groups` claim, which the plugin reads for role
  mapping.
- **Record the generated Client ID and Client secret.**

**2. Authentik — create the Application** (Applications → Create):

- Name: `Jellyfin`, Slug: `jellyfin` (the slug fixes the OID endpoint URL below —
  keep it `jellyfin`).
- Provider: `jellyfin` (from step 1).
- Launch URL: `https://jellyfin.jardoole.xyz/sso/OID/start/authentik`
- Restrict who can obtain a token: bind a policy allowing **`media-admins` OR
  `media-users`** (deny-by-default — randoms with neither group get nothing).
  The admin/user split itself is applied inside the plugin in step 4.

**3. Jellyfin — install the plugin** (Dashboard → Plugins → Repositories):

- Add repository **SSO-Auth** =
  `https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json`
- Catalog tab → install **SSO-Auth** → **restart Jellyfin**.

**4. Jellyfin — configure the plugin** (Dashboard → Plugins → SSO-Auth → Add new
provider):

- Name of OID Provider: `authentik` (must match the redirect-URI suffix)
- OID Endpoint:
  `https://auth.jardoole.xyz/application/o/jellyfin/.well-known/openid-configuration`
- OpenID Client ID: *(Client ID from step 1)*
- OID Secret: *(Client secret from step 1)*
- **Enabled**: checked
- **Enable Authorization by Plugin**: checked (so Roles/Admin Roles below gate
  access)
- Role Claim: `groups`
- Roles: groups allowed to log in — `media-admins` and `media-users` (both)
- Admin Roles: the group that should be Jellyfin admins — `media-admins`
- Save.

**5. Jellyfin — add the login button** (Dashboard → General → Branding → Login
Disclaimer, as raw HTML):

```html
<form action="https://jellyfin.jardoole.xyz/sso/OID/start/authentik">
  <button class="raised block emby-button button-submit">Sign in with SSO</button>
</form>
```

Save and reload. **Validate:** the button redirects to Authentik, login returns
to Jellyfin authenticated; a user in the admin group lands as a Jellyfin admin; a
native mobile/TV client still logs in with a normal Jellyfin account.

## Repeatable porting recipe (per service `<svc>`)

Template = `playbooks/nextcloud.yml` + `roles/nextcloud/`. For each service:

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
| 3 | Radarr | `radarr:5.3.6` | forward-auth (`/api` bypass) | ☐ built, awaiting deploy/validate | wire Prowlarr + qBittorrent; hardlinks on; `/config` restic-backed up to Garage |
| 4 | Sonarr | `sonarr:4.0.2` | forward-auth (`/api` bypass) | ☐ built, awaiting deploy/validate | same as Radarr, TV; `/config` restic-backed up to Garage |
| 5 | Jellyfin | `jellyfin:10.11.2` | in-app OIDC (SSO-Auth plugin) | ☐ built, awaiting deploy/validate | `/dev/dri` + `group_add`; QSV transcode; host-driver override mounts default OFF; SSO via 9p4 plugin (not forward-auth — see "Jellyfin SSO setup"); `/config` restic-backed up to Garage |
| 6 | Jellyseerr | `jellyseerr:2.7.3` | native OIDC (in-app) | ☐ built, awaiting deploy/validate | wire Jellyfin + Radarr + Sonarr; `/config` restic-backed up to Garage |

Order is fundamental → up the stack. **Do not advance until the current gate passes.**

> **Auth correction (this session):** Jellyfin and Jellyseerr are **not** behind
> the Traefik forward-auth middleware. Forward-auth's browser SSO redirect breaks
> Jellyfin's native clients (Android/iOS/TV/Kodi) and double-authenticates
> Jellyseerr's own login/OIDC. Both use their own auth (Jellyfin: user system +
> optional OIDC plugin; Jellyseerr: native OIDC configured in-app), matching the
> master/K8s deploy, where only the *arr ingresses carried forward-auth. Only
> qBittorrent, Prowlarr, Radarr and Sonarr sit behind forward-auth.

> **Build note (this session):** services 3–6 are implemented (roles, playbooks,
> Traefik routes, `group_vars`, backup manifests, inventory groups, applications
> imports) but **not yet deployed or validated**. They are to be deployed and
> gated **one at a time, in order**, each with: its three vault vars in
> `group_vars/<svc>/vault.yml` (`scripts/garage-keygen.sh vault_<svc>_backup_s3`
> + `openssl rand -base64 32` for `vault_<svc>_restic_password`), the *arr
> Authentik forward-auth app (with the `/api` Expression Policy) for Radarr/Sonarr,
> then `make app service=<svc>` and `make verify-backups SERVICE=<svc>`. Jellyfin
> additionally needs the system-layer `gpu-drivers.yml` to have recorded the
> video/render GID fact (the role asserts it). After each *arr first run, vault its
> API key as `vault_<svc>_api_key` for Prowlarr/Jellyseerr to consume.

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

- Confirm valen exposes `*.jardoole.xyz` externally the same way pi-cm5-2/Nextcloud
  does (DNS + any port-forward/tunnel).
- Confirm valen's iGPU presents `/dev/dri/renderD128` before relying on HW transcode.
- Decide Jellyfin auth (native plugin vs forward-auth) at Phase 5.
- Confirm ProtonVPN `+pmp` credentials are valid for NAT-PMP port forwarding.

## Execution constraints (per CLAUDE.md)

No playbook/`make` runs except `make precommit`; only read-only
`uv run ansible … -a` checks for validation; secrets via `/vault`; vault files are
never read.
