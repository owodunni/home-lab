# jellyseerr role

Deploys Jellyseerr — the media request/discovery UI — as a Docker Compose stack on
the media host (valen). Service 6 (final) of the media-stack migration (see
`docs/media-stack-migration.md`). It sits at the top of the stack and wires to
Jellyfin (library/auth), Radarr (movies) and Sonarr (TV).

## What it deploys

Two containers in one stack (`/opt/jellyseerr`):

| Container | Image | Role |
|-----------|-------|------|
| `jellyseerr` | `fallenbagel/jellyseerr` | Request/discovery UI. HTTP on `127.0.0.1:5055`. |
| `config-backup` | `ghcr.io/lobaro/restic-backup-docker` | Restic snapshot of `/config` → Garage S3 (offsite, beelink). |

- WebUI: `https://jellyseerr.jardoole.xyz` via Traefik. **No forward-auth** — see
  the auth note below.
- Config: `/opt/jellyseerr/config` (local bind → `/app/config`). Jellyseerr is not
  a LinuxServer.io image: it takes **no PUID/PGID** and manages config ownership
  itself.
- No media mount — it only talks to the Jellyfin/Radarr/Sonarr APIs over the LAN.

## Auth model (read this)

Jellyseerr is **not behind Authentik forward-auth** (like Jellyfin, unlike the
*arr apps). It has its own user system and **native OIDC**: in **Settings → Users
→ Enable OpenID Connect**, point it at Authentik (issuer
`https://auth.jardoole.xyz/application/o/<slug>/`, client ID/secret from an
Authentik OAuth2/OIDC provider). Wrapping it in forward-auth would
double-authenticate and break its own login/OIDC flow. This mirrors the
master/K8s deploy.

## Prerequisites

- valen in `[services]` (Docker), `[ingress]` (Traefik), `[media]` (shared vars).
- **Jellyfin, Radarr and Sonarr** deployed — wired into Jellyseerr on first run.
- Authentik live (auth layer) for native OIDC.
- Garage up on the `[garage]` host (the first play of `jellyseerr.yml` provisions
  the backup bucket/key).
- Vault secrets in `group_vars/jellyseerr/vault.yml` (via `/vault`):
  - `vault_jellyseerr_backup_s3_access_key` / `_secret_key` — Garage key for the
    config-backup bucket. Generate with
    `scripts/garage-keygen.sh vault_jellyseerr_backup_s3`.
  - `vault_jellyseerr_restic_password` — restic repo password
    (`openssl rand -base64 32`). **Losing it makes existing config snapshots
    unrecoverable.**

## First-run setup (manual, in the WebUI)

After `make app service=jellyseerr` runs and you reach
`https://jellyseerr.jardoole.xyz`:

1. **Sign in with Jellyfin** and point it at the Jellyfin server
   (`http://192.168.1.197:8096` on the LAN), import libraries/users.
2. **Settings → Services → Radarr**: add it (`http://192.168.1.197:7878` +
   `vault_radarr_api_key`), set the movies root folder and quality profile.
3. **Settings → Services → Sonarr**: same with `http://192.168.1.197:8989` +
   `vault_sonarr_api_key`.
4. **Settings → Users → OpenID Connect**: wire SSO against Authentik. Restrict
   the Authentik application to the `media-admins` and `media-users` groups
   (deny-by-default); promote `media-admins` members to Jellyseerr admins. See
   `docs/media-stack-migration.md` → "Authentik groups & access model".

## Config backup (configure once, restore anywhere)

The Jellyfin/Radarr/Sonarr connections, user accounts/permissions, request
history and OIDC settings all live in `/opt/jellyseerr/config`. The `config-backup`
sidecar takes a daily **restic** snapshot of it to a Garage S3 bucket on beelink
(offsite), so the wiring is captured **once** and restorable. Same generic tooling
as every other service:

```bash
make verify-backups  SERVICE=jellyseerr   # exist + fresh? + list every restore point
make restore-backups SERVICE=jellyseerr   # DESTRUCTIVE (typed-confirm): restore /config
# roll back to an older snapshot (id from verify-backups):
make restore-backups SERVICE=jellyseerr TARGETS='config=ab12cd34'
```

Restore stops `jellyseerr`, copies the chosen snapshot back over
`/opt/jellyseerr/config`, then restarts the stack. The `jellyseerr-backup` bucket
and key are provisioned automatically by the first play of `jellyseerr.yml`.

## Validation gate

- WebUI reachable via Traefik; sign-in works (Jellyfin and/or OIDC).
- Radarr and Sonarr connections **Test** green in Settings → Services.
- A request for a title routes to Radarr/Sonarr (appears there) and, once
  downloaded and imported, shows as available from Jellyfin.
- `make verify-backups SERVICE=jellyseerr` lists a fresh snapshot.

## Notes

- The `config-backup` sidecar joins the default compose bridge for normal host
  egress to Garage (Jellyseerr has no VPN).
