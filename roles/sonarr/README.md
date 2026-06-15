# sonarr role

Deploys Sonarr — the TV series manager — as a Docker Compose stack on the media
host (valen). Service 4 of the media-stack migration (see
`docs/media-stack-migration.md`). Identical in shape to the Radarr role; only the
media type (TV vs movies), port, and root folder differ.

## What it deploys

Two containers in one stack (`/opt/sonarr`):

| Container | Image | Role |
|-----------|-------|------|
| `sonarr` | `lscr.io/linuxserver/sonarr` | TV manager. WebUI/API on `127.0.0.1:8989`. |
| `config-backup` | `ghcr.io/lobaro/restic-backup-docker` | Restic snapshot of `/config` → Garage S3 (offsite, beelink). |

- WebUI: `https://sonarr.jardoole.xyz` via Traefik, gated by Authentik
  forward-auth.
- Config: `/opt/sonarr/config` (local bind).
- Data: the whole media tree (`media_data_root`) bind-mounted at `/data`, so
  qBittorrent's `/data/torrents` and Sonarr's `/data/media/tv` share one
  filesystem — required for **import-by-hardlink** (no second copy; the seeding
  torrent and the library file share inodes).

## Prerequisites

- valen in `[services]` (Docker), `[ingress]` (Traefik), `[media]` (shared vars).
- The media data tree on valen's pool (`playbooks/media-storage.yml`).
- `playbooks/media-forward-auth.yml` deployed + the Authentik domain-level
  forward-auth provider/application created, **with an Expression Policy that
  bypasses `/api`** so Prowlarr (indexer sync) and Jellyseerr (requests) can
  reach Sonarr's API behind the same auth.
- **Prowlarr** and **qBittorrent** deployed — wired into Sonarr on first run.
- Garage up on the `[garage]` host (the first play of `sonarr.yml` provisions the
  backup bucket/key).
- Vault secrets in `group_vars/sonarr/vault.yml` (via `/vault`):
  - `vault_sonarr_backup_s3_access_key` / `_secret_key` — Garage key for the
    config-backup bucket. Generate the pair with
    `scripts/garage-keygen.sh vault_sonarr_backup_s3`.
  - `vault_sonarr_restic_password` — restic repo password
    (`openssl rand -base64 32`). **Losing it makes existing config snapshots
    unrecoverable.**

## First-run setup (manual, in the WebUI)

After `make app service=sonarr` runs and you reach `https://sonarr.jardoole.xyz`
(through Authentik first):

1. **Settings → Media Management**: turn **Use Hardlinks instead of Copy** on,
   and add a **Root Folder** of `/data/media/tv`.
2. **Settings → Download Clients → Add → qBittorrent**: point it at valen's LAN
   address (`http://192.168.1.197:8080`); set category `tv` so grabs land in
   `/data/torrents/tv`.
3. **Settings → Indexers**: indexers arrive automatically once Prowlarr's
   **Apps** sync is configured (add Sonarr in Prowlarr with its API key + URL).
4. **Settings → General → Security → API Key**: copy it and vault it as
   `vault_sonarr_api_key` — Prowlarr and Jellyseerr consume it.

## Config backup (configure once, restore anywhere)

The quality/release-profile tuning, root-folder and naming settings, the
Prowlarr/qBittorrent connections, and the API key all live in `/opt/sonarr/config`.
The `config-backup` sidecar takes a daily **restic** snapshot of it to a Garage S3
bucket on beelink (offsite), so the hand-tuned config is captured **once** and
restorable. Same generic tooling as every other service:

```bash
make verify-backups  SERVICE=sonarr   # exist + fresh? + list every restore point
make restore-backups SERVICE=sonarr   # DESTRUCTIVE (typed-confirm): restore /config
# roll back to an older snapshot (id from verify-backups):
make restore-backups SERVICE=sonarr TARGETS='config=ab12cd34'
```

Restore stops `sonarr`, copies the chosen snapshot back over `/opt/sonarr/config`,
then restarts the stack. The `sonarr-backup` bucket and key are provisioned
automatically by the first play of `sonarr.yml`.

## Validation gate

- WebUI reachable via Traefik behind Authentik SSO.
- Sonarr's API answers on the host:
  `curl -fsS http://127.0.0.1:8989/ping` returns OK.
- Indexers present (synced from Prowlarr) and qBittorrent connected (Test passes).
- A test grab downloads in qBittorrent and **imports by hardlink**:
  `ls -li /data/torrents/tv/<file>` and `ls -li /data/media/tv/<...>/<file>` show
  **identical inode numbers** (one file, two names — no duplication).
- `make verify-backups SERVICE=sonarr` lists a fresh snapshot.

## Notes

- The `config-backup` sidecar needs normal host egress to reach Garage; it joins
  the default compose bridge (Sonarr has no VPN — only qBittorrent's traffic goes
  through the torrent VPN).
