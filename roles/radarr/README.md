# radarr role

Deploys Radarr — the movie collection manager — as a Docker Compose stack on the
media host (valen). Service 3 of the media-stack migration (see
`docs/media-stack-migration.md`).

## What it deploys

Two containers in one stack (`/opt/radarr`):

| Container | Image | Role |
|-----------|-------|------|
| `radarr` | `lscr.io/linuxserver/radarr` | Movie manager. WebUI/API on `127.0.0.1:7878`. |
| `config-backup` | `ghcr.io/lobaro/restic-backup-docker` | Restic snapshot of `/config` → Garage S3 (offsite, beelink). |

- WebUI: `https://radarr.jardoole.xyz` via Traefik, gated by Authentik
  forward-auth.
- Config: `/opt/radarr/config` (local bind).
- Data: the whole media tree (`media_data_root`) bind-mounted at `/data`, so
  qBittorrent's `/data/torrents` and Radarr's `/data/media/movies` share one
  filesystem — required for **import-by-hardlink** (no second copy; the seeding
  torrent and the library file share inodes).

## Prerequisites

- valen in `[services]` (Docker), `[ingress]` (Traefik), `[media]` (shared vars).
- The media data tree on valen's pool (`playbooks/media-storage.yml`).
- `playbooks/media-network.yml` (shared `media` Docker network) and
  `playbooks/media-forward-auth.yml` (SSO middleware) deployed + Radarr's own
  Authentik forward-auth provider + application
  created (per-service, domain-level mode), **with an Expression Policy that
  bypasses `/api`** so Prowlarr (indexer sync) and Jellyseerr (requests) can
  reach Radarr's API behind the same auth.
- **Prowlarr** and **qBittorrent** deployed — wired into Radarr on first run.
- Garage up on the `[garage]` host (the first play of `radarr.yml` provisions the
  backup bucket/key).
- Vault secrets in `group_vars/radarr/vault.yml` (via `/vault`):
  - `vault_radarr_backup_s3_access_key` / `_secret_key` — Garage key for the
    config-backup bucket. Generate the pair with
    `scripts/garage-keygen.sh vault_radarr_backup_s3`.
  - `vault_radarr_restic_password` — restic repo password
    (`openssl rand -base64 32`). **Losing it makes existing config snapshots
    unrecoverable.**

## First-run setup (manual, in the WebUI)

After `make app service=radarr` runs and you reach `https://radarr.jardoole.xyz`
(through Authentik first):

1. **Settings → Media Management**: turn **Use Hardlinks instead of Copy** on
   (the whole point of the single `/data` mount), and add a **Root Folder** of
   `/data/media/movies`.
2. **Settings → Download Clients → Add → qBittorrent**: set **Host** `gluetun`,
   **Port** `8080`, SSL off. Radarr and the qBittorrent stack share the external
   `media` network, so Radarr resolves the gluetun container (which owns
   qBittorrent's netns and publishes the WebUI) by name. Do **not** use
   `127.0.0.1` (that's Radarr's own container), valen's LAN IP (the WebUI is
   published on loopback only — nothing listens on the LAN), or the public URL
   (forward-auth blocks API clients). qBittorrent's `172.28.0.0/16` auth-bypass
   whitelist auto-authenticates the call. Set category `movies` so grabs land in
   `/data/torrents/movies`.
3. **Settings → Indexers**: indexers arrive automatically once Prowlarr's
   **Apps** sync is configured (add Radarr in Prowlarr with its API key + URL).
4. **Settings → General → Security → API Key**: copy it and vault it as
   `vault_radarr_api_key` — Prowlarr and Jellyseerr consume it.

## Config backup (configure once, restore anywhere)

The quality/custom-format profiles, root-folder and naming settings, the
Prowlarr/qBittorrent connections, and the API key all live in `/opt/radarr/config`.
The `config-backup` sidecar takes a daily **restic** snapshot of it to a Garage S3
bucket on beelink (offsite), so the hand-tuned config is captured **once** and
restorable. Same generic tooling as every other service:

```bash
make verify-backups  SERVICE=radarr   # exist + fresh? + list every restore point
make restore-backups SERVICE=radarr   # DESTRUCTIVE (typed-confirm): restore /config
# roll back to an older snapshot (id from verify-backups):
make restore-backups SERVICE=radarr TARGETS='config=ab12cd34'
```

Restore stops `radarr`, copies the chosen snapshot back over `/opt/radarr/config`,
then restarts the stack. The `radarr-backup` bucket and key are provisioned
automatically by the first play of `radarr.yml`.

## Validation gate

- WebUI reachable via Traefik behind Authentik SSO.
- Radarr's API answers on the host:
  `curl -fsS http://127.0.0.1:7878/ping` returns OK.
- Indexers present (synced from Prowlarr) and qBittorrent connected (Test passes).
- A test grab downloads in qBittorrent and **imports by hardlink**:
  `ls -li /data/torrents/movies/<file>` and `ls -li /data/media/movies/<...>/<file>`
  show **identical inode numbers** (one file, two names — no duplication).
- `make verify-backups SERVICE=radarr` lists a fresh snapshot.

## Notes

- The `config-backup` sidecar needs normal host egress to reach Garage; it joins
  the default compose bridge (Radarr has no VPN — only qBittorrent's traffic goes
  through the torrent VPN).
