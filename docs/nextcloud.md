# Nextcloud (file sync/share)

Self-hosted Nextcloud replacing Seafile. Compute runs on a Pi (**pi-cm5-2**),
bulk **file data lives on valen's MergerFS pool over NFS**, TLS is terminated by
the co-located Traefik, the **Postgres DB and the file data are both backed up
offsite to Garage** (beelink, at the barn), and login is **SSO via Authentik**
(native OIDC).

- Playbook: `playbooks/nextcloud.yml` (imported by the `applications` layer)
- Role: `roles/nextcloud/`
- Config: `group_vars/nextcloud/{main,vault}.yml`
- Inventory group: `[nextcloud]` → `pi-cm5-2`
- URL: `https://nextcloud.jardoole.xyz`

## Architecture

| Concern | Where |
|---|---|
| App / cron / DB / Redis | `pi-cm5-2`, one compose stack at `/opt/nextcloud` |
| Code + config (`/var/www/html`) | local Docker volume `nextcloud-html` |
| Postgres data | local Docker volume `nextcloud-db` |
| **User file data** | **NFS host mount** of valen's pool subtree `/mnt/storage/nextcloud`, bind-mounted at `/var/www/html/data` |
| DB backup | `pg-dump` → `db-backup` (restic) → Garage `nextcloud-backup` |
| File-data backup | `data-backup` (restic) → Garage `nextcloud-data-backup` |
| Login | Authentik OIDC via the `user_oidc` app |

### Why a host NFS mount (not a Docker NFS volume like Seafile)

The generic restic restore tooling (`roles/backup_restore/tasks/restic.yml`)
restores a snapshot into a scratch dir and `cp -a`s it back to a path **under the
stack dir on the host**. Mounting the pool subtree as a host NFS mount at
`/opt/nextcloud/data` means that copy-back lands in the pool **in place**, so
`make restore-backups SERVICE=nextcloud` restores the file data with no changes
to the shared backup roles. A Docker named volume has no stable host path to copy
back into.

### Why files-on-NFS works (the all_squash trick)

The pool's base export keeps `root_squash`, but the Nextcloud apache image runs
its entrypoint as **root** (it initialises/chowns the data dir) before serving as
**www-data (UID 33)**. So `playbooks/nextcloud.yml` drops an `/etc/exports.d`
entry re-exporting just the `nextcloud/` subtree with `all_squash` →
**UID/GID 33**, and the host mounts it over **NFSv3** (v4 ignores per-subtree
squash for a subdirectory of the same pseudo-filesystem). Both the root-run init
and the www-data-run server then map to 33, which owns the pre-created dir, so all
writes succeed while the rest of the pool keeps `root_squash`. (Seafile did the
same trick squashing to 8000, because *its* container runs as 8000.)

## First deploy

Secrets are already generated and vaulted in `group_vars/nextcloud/vault.yml`
(the deploy is otherwise unattended). Two things need a human first:

1. **DNS** — `nextcloud.jardoole.xyz` must resolve to `pi-cm5-2` (the wildcard
   `*.jardoole.xyz` cert is handled by the ingress layer).

2. **Authentik provider** — create it in the Authentik UI (see next section). Its
   client secret must equal `vault_nextcloud_oidc_client_secret`. If you didn't
   capture the secret at generation time, rotate it (see "Rotating secrets").

Then deploy:

```bash
make app service=nextcloud      # runs playbooks/nextcloud.yml
```

The first `docker compose up` auto-installs Nextcloud using the vaulted admin
credentials (user `admin`); the role waits for the install to finish, switches
background jobs to **Cron**, and configures OIDC.

## SSO — Authentik setup (manual, UI)

Use the `authentik-app` skill for the click-path. In summary, create an
**OAuth2/OpenID Provider** + **Application**:

- **Application slug**: `nextcloud` (the discovery URL in
  `group_vars/nextcloud/main.yml` is `…/application/o/nextcloud/.well-known/…`).
- **Client type**: Confidential.
- **Client ID**: `nextcloud` (`nextcloud_oidc_client_id`).
- **Client secret**: set it to `vault_nextcloud_oidc_client_secret`.
- **Redirect URI**: `https://nextcloud.jardoole.xyz/apps/user_oidc/code`
- **Scopes**: `openid`, `email`, `profile`.
- **Signing key**: the Authentik default; the discovery doc advertises the JWKS.

The role (`roles/nextcloud/tasks/oidc.yml`) installs `user_oidc` and registers the
provider from the vaulted values, mapping `preferred_username` → Nextcloud UID,
`name` → display name, `email` → email. Re-running the playbook upserts the
provider (e.g. after a secret rotation).

> Native OIDC, **not** a Traefik forward-auth: forward-auth would block the
> Nextcloud desktop/mobile sync and WebDAV clients (non-browser auth flows), the
> same reason Jellyfin uses its own auth in this lab.

## Backups

Both backups are restic snapshots to Garage (offsite, over WireGuard) with a
grandfather-father-son retention policy, and both are first-class in the unified
tooling:

```bash
make verify-backups  SERVICE=nextcloud   # exist + fresh? + list every restore point
make restore-backups SERVICE=nextcloud   # DESTRUCTIVE: restore latest of each (typed confirm)
```

| Backup | Engine | Bucket | Schedule |
|---|---|---|---|
| `postgres` | pg_dump → restic | `nextcloud-backup` (`/restic` subpath) | `0 2 * * *` |
| `data` | restic of the NFS data | `nextcloud-data-backup` | `0 4 * * *` |

**Restoring an older snapshot** — pass `TARGETS` with short-IDs from
`make verify-backups`:

```bash
make restore-backups SERVICE=nextcloud TARGETS='postgres=ab12cd34,data=ef56ab78'
```

### Pi storage note (the file-data backup)

The `data-backup` sidecar runs **on the Pi** and reads the file set over the NFS
mount, but restic **streams** to the repo — it never stores a full copy locally.
Its metadata cache is pinned to a dedicated local volume (`restic-cache`,
`RESTIC_CACHE_DIR=/cache`) so the Pi's disk footprint stays at metadata only, not
the dataset. A full file-data **restore** does pull the data back through the Pi
into the pool — expected for a rare DR operation.

> What's **not** in a backup: the `/var/www/html` code/app tree and
> `config/config.php` (instance secret/salt). These are reproducible by a
> reinstall pointing at the restored DB + data; if you want belt-and-braces,
> snapshot `config.php` out of band and keep it with the vault.

## Maintenance

- **Upgrades**: bump `nextcloud_image` one major at a time (the entrypoint runs
  `occ upgrade` and refuses a >1 major jump). Back up DB **and** data first.
- **Rotating secrets**: edit `group_vars/nextcloud/vault.yml`
  (`uv run ansible-vault edit …`) and re-run `make app service=nextcloud`. For the
  OIDC secret, update the Authentik provider to match. **Never** change
  `vault_nextcloud_restic_password` without migrating the repos — it makes
  existing snapshots unrecoverable.
- **occ**: `cd /opt/nextcloud && docker compose exec -u www-data app php occ <cmd>`.
