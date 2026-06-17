# prowlarr role

Deploys Prowlarr — the indexer/tracker manager that syncs indexers to Radarr and
Sonarr — as a Docker Compose stack on the media host (valen). Service 2 of the
media-stack migration (see `docs/media-stack-migration.md`).

## What it deploys

Two containers in one stack (`/opt/prowlarr`):

| Container | Image | Role |
|-----------|-------|------|
| `prowlarr` | `lscr.io/linuxserver/prowlarr` | Indexer manager. WebUI/API on `127.0.0.1:9696`. |
| `config-backup` | `ghcr.io/lobaro/restic-backup-docker` | Restic snapshot of `/config` → Garage S3 (offsite, beelink). |

- WebUI: `https://prowlarr.jardoole.xyz` via Traefik, gated by Authentik
  forward-auth.
- Config: `/opt/prowlarr/config` (local bind). Prowlarr is config-only — no media
  `/data` mount (it manages indexers, it does not touch downloads).

## Prerequisites

- valen in `[services]` (Docker), `[ingress]` (Traefik), `[media]` (shared vars).
- `playbooks/media-network.yml` (shared `media` Docker network) and
  `playbooks/media-forward-auth.yml` (SSO middleware) deployed + Prowlarr's own
  Authentik forward-auth provider + application
  created (per-service, domain-level mode), **with an Expression Policy that
  bypasses `/api`** so Radarr/Sonarr can reach Prowlarr's API behind the same
  auth (matches the master/K8s setup).
- Garage up on the `[garage]` host (the first play of `prowlarr.yml` provisions
  the backup bucket/key).
- Vault secrets in `group_vars/prowlarr/vault.yml` (via `/vault`):
  - `vault_prowlarr_backup_s3_access_key` / `_secret_key` — Garage key for the
    config-backup bucket. Generate the pair with
    `scripts/garage-keygen.sh vault_prowlarr_backup_s3`.
  - `vault_prowlarr_restic_password` — restic repo password
    (`openssl rand -base64 32`). **Losing it makes existing config snapshots
    unrecoverable.**

## First-run setup (manual, in the WebUI)

After `make app service=prowlarr` runs and you reach
`https://prowlarr.jardoole.xyz` (through Authentik first):

1. **Settings → Indexers → Add Indexer**: add public indexers (1337x, The Pirate
   Bay, YTS, EZTV, …). Test each before saving.
2. **Settings → General → Security → API Key**: copy it and vault it as
   `vault_prowlarr_api_key` — Radarr/Sonarr will use it to sync indexers.
3. **Settings → Apps** (added once Radarr/Sonarr exist): connect Radarr and
   Sonarr with `Full Sync` so indexers propagate automatically. All three share
   the `media` network, so address them by container name —
   **Prowlarr Server** `http://prowlarr:9696`, **Radarr** `http://radarr:7878`,
   **Sonarr** `http://sonarr:8989` (each with its `vault_<svc>_api_key`). Using
   the internal hostnames keeps the sync off the public forward-auth'd URL.

## Config backup (configure once, restore anywhere)

The indexer set, their credentials, the Radarr/Sonarr app connections, and the
API key all live in `/opt/prowlarr/config`. The `config-backup` sidecar takes a
daily **restic** snapshot of it to a Garage S3 bucket on beelink (offsite), so the
hand-built indexer config is captured **once** and restorable. Same generic
tooling as every other service:

```bash
make verify-backups  SERVICE=prowlarr   # exist + fresh? + list every restore point
make restore-backups SERVICE=prowlarr   # DESTRUCTIVE (typed-confirm): restore /config
# roll back to an older snapshot (id from verify-backups):
make restore-backups SERVICE=prowlarr TARGETS='config=ab12cd34'
```

Restore stops `prowlarr`, copies the chosen snapshot back over
`/opt/prowlarr/config`, then restarts the stack. The `prowlarr-backup` bucket and
key are provisioned automatically by the first play of `prowlarr.yml`.

## Validation gate

- WebUI reachable via Traefik behind Authentik SSO.
- A test indexer added and its **Test** passes.
- Prowlarr's API answers on the host:
  `curl -fsS http://127.0.0.1:9696/ping` returns OK.
- `make verify-backups SERVICE=prowlarr` lists a fresh snapshot (after the first
  backup run, or force one by restarting the `config-backup` container).

## Notes

- The `config-backup` sidecar needs normal host egress to reach Garage; it joins
  the default compose bridge (Prowlarr has no VPN — unlike qBittorrent, indexer
  and *arr-sync traffic must not go through the torrent VPN).
