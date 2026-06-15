# jellyfin role

Deploys Jellyfin — the media streaming server with Intel QuickSync hardware
transcoding — as a Docker Compose stack on the media host (valen). Service 5 of
the media-stack migration (see `docs/media-stack-migration.md`).

## What it deploys

Two containers in one stack (`/opt/jellyfin`):

| Container | Image | Role |
|-----------|-------|------|
| `jellyfin` | `lscr.io/linuxserver/jellyfin` | Media server + QSV transcoding. HTTP on `127.0.0.1:8096`. |
| `config-backup` | `ghcr.io/lobaro/restic-backup-docker` | Restic snapshot of `/config` → Garage S3 (offsite, beelink). |

- WebUI/clients: `https://jellyfin.jardoole.xyz` via Traefik. **No forward-auth**
  — see the auth note below.
- Config: `/opt/jellyfin/config` (local bind).
- Library: the *arr library subtree (`media_data_root/media`) bind-mounted
  **read-only** at `/media` (Jellyfin streams it, never writes it).
- GPU: `/dev/dri` mapped in, with the host `video`/`render` GIDs added via
  `group_add` for QuickSync.

## Auth model (read this)

Jellyfin is **deliberately not behind Authentik forward-auth**, unlike the *arr
apps. Forward-auth intercepts every request with a browser SSO redirect, and
native Jellyfin clients (Android/iOS/Android TV/Kodi) cannot follow it — it
breaks them. Jellyfin uses its **own user system**; for SSO, install an in-app
OIDC/SSO plugin and point it at Authentik. This mirrors the master/K8s deploy,
whose Jellyfin ingress also omitted the forward-auth middleware.

## Hardware transcoding (Intel QuickSync / VA-API)

Base passthrough is always on: `devices: /dev/dri:/dev/dri` plus `group_add` of
the host `video`/`render` GIDs. Those GIDs are discovered by
`playbooks/gpu-drivers.yml` (system layer) and stored as the local fact
`ansible_local.media_gpu.*`; the role **asserts the fact is present** and fails
with a clear message if the GPU layer has not run.

### Host-driver override mounts (default OFF)

`group_vars/jellyfin/main.yml` has `jellyfin_mount_host_va_drivers: false`. The
four mounts it gates bind valen's host VA-API / oneVPL / libmfx-gen / libigdgmm
over the container's bundled copies — the workaround the old beelink (Intel N150)
needed because its container drivers predated N150 support.

The pinned image (10.11.2) bundles a far newer driver stack, so the override is
usually unnecessary, and binding absolute host paths that don't match valen's
installed driver version would **break container startup**. Leave it off, validate
QSV, and only flip it on (after confirming the `jellyfin_va_*_host` paths exist on
valen) if hardware encoding fails with a driver/version mismatch.

## Prerequisites

- valen in `[services]` (Docker), `[ingress]` (Traefik), `[media]` (shared vars).
- **Intel GPU drivers + GID fact** on valen (`playbooks/gpu-drivers.yml`, system
  layer) — the role asserts `ansible_local.media_gpu.{video,render}_gid`.
- The media library on valen's pool (`playbooks/media-storage.yml`).
- Garage up on the `[garage]` host (the first play of `jellyfin.yml` provisions
  the backup bucket/key).
- Vault secrets in `group_vars/jellyfin/vault.yml` (via `/vault`):
  - `vault_jellyfin_backup_s3_access_key` / `_secret_key` — Garage key for the
    config-backup bucket. Generate with
    `scripts/garage-keygen.sh vault_jellyfin_backup_s3`.
  - `vault_jellyfin_restic_password` — restic repo password
    (`openssl rand -base64 32`). **Losing it makes existing config snapshots
    unrecoverable.**

## First-run setup (manual, in the WebUI)

After `make app service=jellyfin` runs and you reach
`https://jellyfin.jardoole.xyz`:

1. Complete the setup wizard (create the admin user).
2. **Dashboard → Libraries → Add**: Movies → `/media/movies`, Shows →
   `/media/tv`.
3. **Dashboard → Playback → Transcoding**: Hardware acceleration **Intel
   QuickSync (QSV)**, QSV device `/dev/dri/renderD128`; enable HW decoding for
   H264/HEVC/VP9/AV1 and the Low-Power H.264/HEVC encoders.
4. (Optional SSO) install an OIDC plugin and configure it against Authentik.

## Config backup (configure once, restore anywhere)

Users, library definitions, transcoding settings, plugins and API keys live in
`/opt/jellyfin/config`. The `config-backup` sidecar takes a daily **restic**
snapshot of it to a Garage S3 bucket on beelink (offsite). The dir also holds the
re-fetchable metadata/image cache, but restic dedupes so incrementals stay small.
Same generic tooling as every other service:

```bash
make verify-backups  SERVICE=jellyfin   # exist + fresh? + list every restore point
make restore-backups SERVICE=jellyfin   # DESTRUCTIVE (typed-confirm): restore /config
# roll back to an older snapshot (id from verify-backups):
make restore-backups SERVICE=jellyfin TARGETS='config=ab12cd34'
```

Restore stops `jellyfin`, copies the chosen snapshot back over
`/opt/jellyfin/config`, then restarts the stack. The `jellyfin-backup` bucket and
key are provisioned automatically by the first play of `jellyfin.yml`.

## Validation gate

- WebUI reachable via Traefik (its own login page, no SSO redirect).
- `vainfo` inside the container lists QSV profiles:
  `docker exec jellyfin vainfo --display drm --device /dev/dri/renderD128`.
- A transcoding playback session shows GPU use (`intel_gpu_top` on valen).
- Library plays back in a browser and a native client.
- `make verify-backups SERVICE=jellyfin` lists a fresh snapshot.

## Notes

- The `config-backup` sidecar joins the default compose bridge for normal host
  egress to Garage (Jellyfin has no VPN).
