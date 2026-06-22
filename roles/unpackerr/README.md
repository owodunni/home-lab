# unpackerr role

Deploys [Unpackerr](https://github.com/unpackerr/unpackerr) — the archive
extractor for the *arr stack — as a Docker Compose stack on the media host
(valen).

## Why it exists

Many scene releases ship as a **multi-volume RAR set** (`.rar` + `.r00`, `.r01`,
…). Sonarr and Radarr only rename/hardlink already-extracted media — they cannot
unpack archives — so an archived download sits stuck in the queue with "no files
eligible for import" forever. Unpackerr polls the *arr queues over the shared
media network, extracts those archives in place, and the *arr's normal import
then hardlinks the extracted media into the library.

## What it deploys

One container in one stack (`/opt/unpackerr`):

| Container | Image | Role |
|-----------|-------|------|
| `unpackerr` | `ghcr.io/unpackerr/unpackerr` | Watches Sonarr/Radarr queues, extracts archives, cleans up extracted copies after import. |

- **No WebUI** (headless) → no Traefik route.
- **Stateless** (all config is env-driven from `group_vars/unpackerr`) → no
  config dir and no config-backup sidecar, unlike the *arr roles.
- Runs as the pool media account (`media_puid`/`media_pgid`, 8000) so extracted
  files match the rest of the tree and can be hardlinked.
- Mounts the whole media tree (`media_data_root`) at **the same `/data` path the
  *arr apps use** — required so the download paths in the *arr queues resolve
  identically inside this container.

## Seeding safety

Unpackerr deletes **only the files it extracted**, after the *arr imports them
(by hardlink, so the library keeps the data). `UN_*_DELETE_ORIG` is pinned
`false` (`unpackerr_delete_original`), so the original `.rar`/`.r00…` parts are
never touched and **qBittorrent keeps seeding** them.

## Prerequisites

- valen in `[services]` (Docker) and `[media]` (shared vars).
- `playbooks/media-network.yml` (shared `media` Docker network) deployed.
- **Sonarr** and **Radarr** deployed and reachable on that network.
- The media data tree on valen's pool (`playbooks/media-storage.yml`).
- Vault secrets in `group_vars/unpackerr/vault.yml` (via `/vault`):
  - `vault_unpackerr_sonarr_api_key` — Sonarr → Settings → General → API Key
  - `vault_unpackerr_radarr_api_key` — Radarr → Settings → General → API Key

## Deploy

```bash
make app service=unpackerr
```

Verify it connected to both apps:

```bash
uv run ansible unpackerr -a "docker logs --tail 30 unpackerr"
```

You should see it log the Sonarr and Radarr instances at startup with no auth
errors.
