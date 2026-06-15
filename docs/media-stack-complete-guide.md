# Media Stack — Complete Guide

Home media automation and streaming on **valen**: a Netflix-like request/stream
experience backed by API-driven download automation and hardlink-efficient
storage.

**Stack**: Jellyfin (streaming) + Jellyseerr (requests) + Radarr (movies) +
Sonarr (TV) + Prowlarr (indexers) + qBittorrent+VPN (downloads).

**Architecture**: each service is its own **Docker Compose stack** deployed by a
per-service Ansible role (the `applications` layer). This is the operational
overview + index; the **authoritative per-service detail lives in each role's
`README.md`** and the auth/migration detail in
[`media-stack-migration.md`](media-stack-migration.md). This guide does not
duplicate those — it ties them together and covers the cross-service concerns
(data flow, end-to-end validation, troubleshooting, maintenance).

> **Reference**: [TRaSH Guides](https://trash-guides.info/) for *arr best practices.

---

## Architecture overview

### Data flow

```
User request (Jellyseerr)
        ↓
   Radarr / Sonarr (automation)
        ↓
   Prowlarr (search indexers)
        ↓
   qBittorrent → VPN (download)
        ↓
   /data/torrents/{movies,tv}/        in-progress + completed downloads
        ↓
   Radarr / Sonarr (import by HARDLINK — no copy)
        ↓
   /data/media/{movies,tv}/           permanent library
        ↓
   Jellyfin (stream, QuickSync transcode)
```

### How it differs from the old K8s deploy

This stack was ported from a Kubernetes/Helm deploy on **beelink** to Docker
Compose on **valen**. The consequences that matter operationally:

| Aspect | Old (K8s on beelink) | Now (Compose on valen) |
|---|---|---|
| Orchestration | Helm releases, one namespace | One Compose stack per service under `/opt/<svc>` |
| Inspect / logs | `kubectl logs/exec -n media …` | `docker logs <c>` / `docker exec <c> …` |
| Storage | shared PVC | local **bind mount** `/mnt/storage/media` → `/data` |
| Jellyfin mount | PVC at `/media`, libraries `/media/media/*` | library subtree at `/media`, libraries **`/media/movies`**, **`/media/tv`** |
| App-to-app URL | cluster DNS `radarr-app:7878` | valen's LAN IP **`http://192.168.1.197:<port>`** |
| Auth | none (built-in only) | Authentik forward-auth (*arr) + SSO/OIDC (Jellyfin/Jellyseerr) |
| Backups | restic to MinIO | restic → Garage S3 (offsite on beelink), generic `make verify/restore-backups` |

### Storage layout (hardlinks)

Every download/library app bind-mounts the **whole** media tree at one mount so
downloads and the library sit on **one filesystem** — the requirement for
import-by-hardlink (same inode in both places: no duplicate storage, seed while
streaming). Created by `playbooks/media-storage.yml`; owned by the pool media
account (UID/GID 8000 → `PUID`/`PGID`).

```
/mnt/storage/media/            ← on valen's pool; bind-mounted at /data (RW), /media (RO for Jellyfin)
├── torrents/
│   ├── incomplete/            qBittorrent in-progress
│   ├── movies/                qBittorrent "movies" category  → Radarr import source
│   └── tv/                    qBittorrent "tv" category      → Sonarr import source
└── media/
    ├── movies/                Radarr root folder (hardlinked from torrents/movies)
    └── tv/                    Sonarr root folder (hardlinked from torrents/tv)
```

Container views of this one tree:

- qBittorrent, Radarr, Sonarr: `/data` (read-write) — so `/data/torrents` and
  `/data/media` are on the same fs.
- Jellyfin: only the `media/` subtree, **read-only at `/media`** → libraries are
  `/media/movies` and `/media/tv`.
- Prowlarr, Jellyseerr: no media mount (config-only; they talk APIs).

---

## Services

| Service | URL | Container port | Role README | Auth |
|---|---|---|---|---|
| qBittorrent + VPN | <https://qbittorrent.jardoole.xyz> | `8080` | [`roles/qbittorrent/README.md`](../roles/qbittorrent/README.md) | forward-auth |
| Prowlarr | <https://prowlarr.jardoole.xyz> | `9696` | [`roles/prowlarr/README.md`](../roles/prowlarr/README.md) | forward-auth (`/api` bypass) |
| Radarr | <https://radarr.jardoole.xyz> | `7878` | [`roles/radarr/README.md`](../roles/radarr/README.md) | forward-auth (`/api` bypass) |
| Sonarr | <https://sonarr.jardoole.xyz> | `8989` | [`roles/sonarr/README.md`](../roles/sonarr/README.md) | forward-auth (`/api` bypass) |
| Jellyfin | <https://jellyfin.jardoole.xyz> | `8096` | [`roles/jellyfin/README.md`](../roles/jellyfin/README.md) | in-app OIDC (SSO-Auth plugin) |
| Jellyseerr | <https://jellyseerr.jardoole.xyz> | `5055` | [`roles/jellyseerr/README.md`](../roles/jellyseerr/README.md) | native OIDC |

Each WebUI port is published on `127.0.0.1` only; Traefik on valen terminates TLS
(wildcard cert) and proxies to it. Inter-service API calls cross Compose stacks,
so they use **valen's LAN address** `http://192.168.1.197:<port>` — not container
names and not `127.0.0.1` (that would resolve to the calling container).

**Auth** is three mechanisms by design (not forward-auth for everything — it
breaks Jellyfin's native clients). The full Authentik setup (provider/app,
group model, forward-auth middleware, Jellyfin SSO plugin) is in
[`media-stack-migration.md`](media-stack-migration.md) → "Auth model".

---

## Deployment & first-time setup

**Deploy** is one service at a time, in dependency order, validating each gate
before the next — the repeatable recipe, prerequisites, and live status table are
in [`media-stack-migration.md`](media-stack-migration.md). Per service:
`make app service=<svc>` then `make verify-backups SERVICE=<svc>`.

**Configure** in the same order (each README's "First-run setup" section has the
exact WebUI steps — follow those, this is just the sequence and why):

1. **[qBittorrent](../roles/qbittorrent/README.md)** — first: everything else
   downloads through it. Set the WebUI password + localhost/subnet auth bypass,
   default save path `/data/torrents`, categories `movies`/`tv`. Confirm VPN
   egress before anything else.
2. **[Prowlarr](../roles/prowlarr/README.md)** — add indexers; copy its API key
   and vault it as `vault_prowlarr_api_key`.
3. **[Radarr](../roles/radarr/README.md)** — enable hardlinks, root folder
   `/data/media/movies`, add qBittorrent (`http://192.168.1.197:8080`, category
   `movies`). Then in Prowlarr → **Apps** add Radarr (`http://192.168.1.197:7878`
   + Radarr's API key, Full Sync). Vault Radarr's API key as `vault_radarr_api_key`.
4. **[Sonarr](../roles/sonarr/README.md)** — same pattern for TV: root folder
   `/data/media/tv`, qBittorrent category `tv`, register in Prowlarr → Apps
   (`http://192.168.1.197:8989`). Vault as `vault_sonarr_api_key`.
5. **[Jellyfin](../roles/jellyfin/README.md)** — admin user; libraries
   **Movies → `/media/movies`**, **Shows → `/media/tv`**; enable QuickSync
   transcoding; optionally the SSO-Auth plugin.
6. **[Jellyseerr](../roles/jellyseerr/README.md)** — connect Jellyfin
   (`http://192.168.1.197:8096`), Radarr (`…:7878`) and Sonarr (`…:8989`) with
   their vaulted API keys; wire native OIDC.

---

## End-to-end validation

After all six are up and configured, confirm the whole pipeline:

1. **Request** a known title (e.g. an open-source film) in Jellyseerr → status
   shows *Requested*.
2. **Radarr/Sonarr** picks it up → Activity → Queue shows a grab.
3. **qBittorrent** shows the torrent under the right category, behind the VPN.
4. **Import** completes → Radarr/Sonarr History shows *Imported*.
5. **Hardlink check** (the storage-efficiency gate) — same inode in both trees:
   ```bash
   # on valen (host paths), or via a read-only ansible check:
   uv run ansible media -a "ls -li /mnt/storage/media/torrents/movies/"
   uv run ansible media -a "ls -li /mnt/storage/media/media/movies/"
   # identical inode + link count 2 = hardlink (one copy). Different inode = a
   # copy happened → check Radarr/Sonarr "Use Hardlinks instead of Copy" is ON.
   ```
6. **Jellyfin** shows the title (auto-scan or Dashboard → Scan Library) and plays
   back; a transcoding session uses the GPU (`intel_gpu_top` on valen).
7. **Jellyseerr** flips the request to *Available*.

Each service's own validation gate (VPN egress, QSV profiles, API `/ping`, etc.)
is in its README.

---

## Troubleshooting

All inspection is now **Docker**, on valen (`docker ps`, `docker logs <c>`,
`docker exec <c> …`). Containers are named for the service (`qbittorrent`,
`gluetun`, `radarr`, `sonarr`, `prowlarr`, `jellyfin`, `jellyseerr`).

**App-to-app "Connection failed" (Radarr↔Prowlarr, Jellyseerr↔*arr)**
Each app is a separate Compose stack — they cannot reach each other by container
name or `127.0.0.1`. Use valen's LAN IP `http://192.168.1.197:<port>` and verify
the API key matches the target's Settings → General → Security → API Key. The
*arr `/api` path is exempted from forward-auth (Expression Policy), so app-to-app
calls bypass SSO — see the migration doc.

**Radarr/Sonarr find nothing**
Test indexers in Prowlarr (Indexers → Test All); confirm Prowlarr → Apps shows
Radarr/Sonarr synced; check the quality profile allows the release.

**Download stuck at 0%**
Confirm VPN is healthy: `docker exec gluetun wget -qO- https://ipinfo.io/ip`
returns a ProtonVPN IP (not home), and `docker exec gluetun cat
/tmp/gluetun/forwarded_port` is non-empty. Check disk space on the pool. A dead
tunnel = no peers (kill-switch working as intended).

**Storage usage doubled (hardlinks not working)**
Different inodes between `torrents/` and `media/` means a copy occurred. Ensure
"Use Hardlinks instead of Copy" is ON in Radarr/Sonarr, and that both paths are
under the **same `/data` mount** (they are by construction — one bind mount). Both
trees are on one filesystem, so hardlinks must work when the setting is on.

**Jellyfin library empty / can't read files**
Libraries must point at **`/media/movies`** and **`/media/tv`** (the `media/`
subtree is mounted at `/media`, read-only). Files must be readable by the media
account (UID/GID 8000). Trigger Dashboard → Scan Library.

**Jellyfin won't transcode / playback error**
`docker exec jellyfin vainfo --display drm --device /dev/dri/renderD128` must list
QSV profiles. If it fails, the GPU layer (`playbooks/gpu-drivers.yml`) may not
have run, or the host-driver override mounts may be needed — see the Jellyfin
README's transcoding section. Try Direct Play to isolate transcoding from a codec
issue.

**Signed in but bounced to the Authentik dashboard / SSO redirect loop (*arr)**
A forward-auth wiring issue (cookie domain, trusted forwarders, outpost provider
assignment), fully diagnosed in
[`media-stack-migration.md`](media-stack-migration.md) → "Forward-auth setup →
Troubleshooting".

**Pool full**
Lower qBittorrent seeding limits, delete watched/unmonitored content in
Radarr/Sonarr, or add a drive to the MergerFS pool. Check usage:
`uv run ansible media -a "df -h /mnt/storage"`.

---

## Backups

Every service's `/config` is captured by a `config-backup` **restic** sidecar to a
per-service Garage S3 bucket on **beelink** (offsite, over WireGuard), on a
staggered nightly schedule. The hand-tuned setup (qBittorrent WebUI config,
Prowlarr indexers, *arr profiles + connections + API keys, Jellyfin
users/libraries, Jellyseerr wiring/OIDC) is therefore captured once and
restore-any-snapshot. The bulk media library is **not** backed up (replaceable —
re-download/re-import).

Generic tooling, identical for every service:

```bash
make verify-backups  SERVICE=<svc>   # exist + fresh? + list every restore point
make restore-backups SERVICE=<svc>   # DESTRUCTIVE (typed-confirm): restore latest /config
# roll back to an older snapshot (id from verify-backups):
make restore-backups SERVICE=<svc> TARGETS='config=ab12cd34'
```

Full manifest schema and engine detail: run `/backups` or see CLAUDE.md →
"Backups: verify & restore".

---

## Maintenance

**Automated**: nightly restic config backups (staggered 04:00–09:00); Sonarr/Radarr
RSS + upgrade checks; qBittorrent seeding management; valen HDD spins down after
20 min idle (active media use keeps it spinning — expected).

**Periodic (manual)**:

- Review pool usage: `uv run ansible media -a "df -h /mnt/storage"`.
- Check Prowlarr indexer health (Indexers → Test All).
- Bump pinned image tags in `group_vars/<svc>/main.yml`, redeploy
  `make app service=<svc>`, re-run its validation gate.
- Periodically `make verify-backups SERVICE=<svc>` for each service; test a
  restore before you actually need one.

---

## Quick reference

```bash
# Deploy / redeploy one service
make app service=radarr

# Inspect (on valen)
docker ps
docker logs -f radarr
docker exec gluetun wget -qO- https://ipinfo.io/ip      # VPN egress IP
docker exec jellyfin vainfo --display drm --device /dev/dri/renderD128

# Read-only checks from the control node (allowed by CLAUDE.md)
uv run ansible media -a "df -h /mnt/storage"
uv run ansible media -a "ls -li /mnt/storage/media/media/movies/"

# Backups
make verify-backups  SERVICE=jellyfin
make restore-backups SERVICE=jellyfin

# Inter-service base URLs (valen LAN IP)
# qBittorrent http://192.168.1.197:8080   Prowlarr http://192.168.1.197:9696
# Radarr      http://192.168.1.197:7878   Sonarr   http://192.168.1.197:8989
# Jellyfin    http://192.168.1.197:8096   Jellyseerr http://192.168.1.197:5055
```

---

## See also

- [`media-stack-migration.md`](media-stack-migration.md) — auth model (forward-auth
  + Jellyfin SSO + Jellyseerr OIDC), Authentik group/access model, the per-service
  porting recipe, and the live deployment status table.
- Per-service `roles/<svc>/README.md` — what each deploys, prerequisites, exact
  first-run WebUI steps, validation gate, and backup details.
