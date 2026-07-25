# Immich Deployment Design

**Date:** 2026-07-25
**Status:** Approved — ready for implementation plan
**Author:** Alexander Poole (with Claude)

## Goal

Deploy [Immich](https://immich.app/) — a self-hosted photo and video management
platform — as a Google Photos replacement for the household (Alex + wife). This
is the last major service planned in the effort to be able to leave Google's
services. Immich must integrate with the existing home-lab conventions: layered
Ansible, Authentik SSO, the generic manifest-driven 3-2-1 backup tooling, and
LAN-only ingress reachable remotely over the existing WireGuard.

Current data: ~100 GB (Alex) + ~100 GB (wife) migrating in from Google Photos.
Expected ceiling ~1 TB combined over the next few years — comfortably within
valen's pool and beelink's offsite pool (`HighDiskUsage` headroom).

## Placement

**Host: valen.** Rationale (drawbacks of the alternative — `pi-cm5-2` + NFS —
in parentheses):

- **Hardware ML.** Immich's `machine-learning` container (face recognition +
  CLIP smart search) runs OpenVINO-accelerated on valen's Intel iGPU. (On a CM5
  it is CPU-only ARM inference — face-detection over a large library crawls for
  days and pins the Pi.)
- **Postgres must be local NVMe.** Immich's DB uses pgvector/VectorChord with
  `--data-checksums`; Postgres data over NFS is a known corruption footgun. (The
  Pi path forces the DB onto eMMC — wearing it and still compute-starved.)
- **Originals are bulk data already on valen's pool** — a local bind mount, not
  every asset op round-tripping over NFS.
- **Pattern match** with the media co-location model (Jellyfin/arr): compute +
  storage + iGPU together, Traefik + Garage already present.

**Accepted drawbacks of valen:** it is already dense (arr stack, Jellyfin,
Garage, NFS server, mailcow). Immich's ML container is RAM-hungry (~2–4 GB
resident), and valen is a known single point of overload (see the 2026-07-20
outage post-mortem). The iGPU is now shared three ways (Jellyfin transcode,
Immich transcode, Immich ML) — acceptable for household load.

### Structure (one-line-move convention)

- New inventory group `[immich]` → valen in `hosts.ini`.
- `group_vars/immich/{main.yml,vault.yml}` — all config + secrets travel with the
  service; the role carries **no** `defaults/`.
- `roles/immich` + `playbooks/immich.yml`.
- Added to the **applications** layer playbook (after `auth` — needs OIDC live —
  and depends on ingress/docker/storage below it).
- `make app service=immich` deploys it (filename = group = `group_vars/` dir).

valen is already in `[ingress]`, `[services]`, `[media]`, `[garage]`, so it
routes `immich.jardoole.xyz`, runs Docker, has the GPU facts, and hosts Garage
locally.

## Compose stack

Four containers, from the upstream template, image tags **pinned** (repo
convention — never `:release`):

- `immich-server` — API + web, published on `127.0.0.1:2283` (Traefik proxies).
- `immich-machine-learning` — OpenVINO-accelerated (see Hardware acceleration).
- `redis` — valkey (already pinned by digest in the template).
- `database` — Immich's `ghcr.io/immich-app/postgres:14-vectorchord…` image
  (pgvector + VectorChord + `--data-checksums`), `shm_size: 128mb`.

## Storage layout

- **Originals → valen's MergerFS pool.** `UPLOAD_LOCATION` is a dedicated dir
  under the pool (bulk data, SnapRAID-parity-protected locally). Owned by the
  pool media account (`media_puid`/`media_pgid` from `group_vars/media`).
  - *Caveat:* the pool is HDD with spin-down; gallery/thumbnail access incurs
    occasional spin-up latency and will keep disks spun up during active use.
    Acceptable for a household; documented so it is not a surprise.
- **Postgres `DB_DATA_LOCATION` → valen NVMe** (local SSD — never the pool,
  never NFS), same as every other DB in the lab. Leave `DB_STORAGE_TYPE`
  default (SSD).
- Redis + ML `model-cache` → local.

## Backups

**No new postgres backup engine.** Immich's **built-in scheduled DB backup** is
the dump producer, and the existing `type: restic` engine captures its output.
This is deliberately more robust than a hand-rolled `pg_dump` sidecar: Immich's
built-in dumper is version-matched to its own schema and VectorChord/pgvector
extensions and maintained upstream, so it keeps working correctly across Immich
upgrades — no risk of our dump flags drifting from what the extensions need.

Two `type: restic` entries in `group_vars/immich/main.yml` (`backups:` list),
each a restic repo in its own Garage bucket on valen, both mirrored offsite to
beelink by the `backup` layer with a read-only key.

### 1. Database — built-in dump, unpacked, then restic

- Immich's built-in DB backup **enabled** (Administration → Settings → Backup;
  daily, retention "keep last N" small — restic holds the real history). Writes
  `UPLOAD_LOCATION/backups/immich-<ts>.sql.gz`.
- **Unpack step** (small sidecar / scheduled task on valen): decompress the
  newest `.sql.gz` to a plain `.sql` in a dedicated dir
  (`{{ immich_dir }}/db-dump/immich.sql`), atomic temp-then-rename so restic
  never snapshots a half-written file.
  - *Why unpack:* restic's content-defined chunking dedups a plain `.sql` across
    nightly snapshots (stores only the delta), whereas a `.sql.gz` changes
    wholesale each night (~one full copy per snapshot). For a ~100 MB DB that is
    ~200 MB total vs ~10 GB/year.
- **Freshness guard:** the unpack emits output **only if** the source `.sql.gz`
  mtime is within the expected window. If Immich's internal dump job silently
  dies, no fresh `.sql` is produced, the restic snapshot ages, and
  `BackupLocalStale` fires — instead of restic snapshotting a stale dump forever
  green. This preserves the freshness signal a bare "restic-the-gz-as-is"
  approach would lose. (This is the concern that originally argued for a
  dedicated postgres engine; the guard recovers it within the built-in approach.)
- `type: restic` over the `db-dump/` dir → `immich-postgres-backup` bucket,
  `max_age_hours` with slack over the built-in dump schedule.
- **Restore** is a runbook, not a custom engine: restic-restore `immich.sql`,
  then load via Immich's documented CLI path — the `search_path` transform piped
  through `psql`:

  ```
  sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" immich.sql \
    | psql --dbname=<db> --username=<user> --single-transaction --set ON_ERROR_STOP=on
  ```

  into a **fresh** DB (no prior server run) or with `DB_SKIP_MIGRATIONS=true`;
  or use Immich's built-in restore-from-backup UI (re-gzip / upload the dump).

### 2. Originals — restic engine

- `type: restic` over `UPLOAD_LOCATION`, backing up **originals only**:
  `library/`, `upload/`, `profile/`. **Excludes** the re-generatable `thumbs/`
  and `encoded-video/` (rebuilt via Immich jobs on restore) and the built-in
  `backups/` dir (the `.sql.gz` lives there; the unpacked `.sql` in `db-dump/`
  is what entry 1 backs up).
- Own Garage bucket (e.g. `immich-data-backup`).
- **Never** back up `DB_DATA_LOCATION` (live Postgres files = inconsistent); the
  logical dump above is the DB's backup.

*Alternative considered:* a single restic entry over the whole `UPLOAD_LOCATION`
(originals + the unpacked `.sql`). Simpler (one bucket/key), but bundles the tiny
critical DB dump into the large photo repo with shared retention. Two entries
keeps the DB independently restorable in a tiny repo and matches the authentik
two-entry shape; chosen for that reason.

### Consistency note

Neither entry is atomic with the other (DB dump and file backup run on their own
schedules). This is acceptable for a personal library: worst case a handful of
very recent photos are on disk but not yet in the restored DB, and are
re-scannable. Not worth stopping the server. This matches Immich's "DB first,
files second" guidance direction.

### Offsite + monitoring

- Garage buckets/keys provisioned via the `garage-keys` convention
  (pre-generate + import; never `garage key create`). Read-only offsite key
  added to `[backup_mirror]` so beelink pulls both buckets.
- The per-service backup-freshness exporter picks up both manifest entries
  automatically → `BackupLocalStale` / `BackupMirrorStale` cover Immich.

## SSO — Authentik native OIDC (not forward-auth)

Like Jellyfin, Immich is **deliberately not** behind the Authentik forward-auth
middleware: forward-auth intercepts every request with a browser SSO redirect
that native Immich mobile clients cannot follow. Immich uses its own OAuth
against Authentik (`immich-sso.md`).

- Provider/application created via the `authentik-app` skill. OAuth2/OIDC
  provider with three redirect URIs (Strict/Authorization):
  - `app.immich:///oauth-callback` (mobile app)
  - `https://immich.jardoole.xyz/auth/login`
  - `https://immich.jardoole.xyz/user-settings`
- Immich OAuth config (Administration → Settings → OAuth): `issuer_url`
  `https://auth.jardoole.xyz/application/o/<slug>/`, `client_id`,
  `client_secret`. Client secret in `group_vars/immich/vault.yml` (`vault_`
  prefix).
- **Access control:** restrict to an Authentik **`Immich Users` group** binding.
- **Login policy:** OAuth **auto-register on**; keep **local password login
  enabled initially** as a fallback, then disable password login once OAuth is
  verified working (incl. mobile app).

## Hardware acceleration (valen iGPU)

Enable both, reusing the discovered `ansible_local.media_gpu.*` GID facts for
`/dev/dri` passthrough (same mechanism as Jellyfin; iGPU shared — fine for
household load):

- **ML inference** — OpenVINO (`hwaccel.ml.yml` `openvino`) for face detection +
  CLIP.
- **Video transcoding** — QuickSync (`hwaccel.transcoding.yml` `quicksync`).

## Ingress / networking / firewall

- valen's co-located Traefik: `Host(immich.jardoole.xyz)` → `127.0.0.1:2283`,
  loopback bind. Split-horizon DNS resolves `immich.jardoole.xyz` →
  `valen.jardoole.xyz` → valen LAN IP.
- **Traefik tuning for Immich:** large video uploads — ensure no restrictive
  request-body-size limit and buffering does not choke big uploads; websocket
  support for the app. Confirm against the current Traefik config during
  implementation.
- **Remote access = WireGuard/VPN only.** No new internet exposure. Phones reach
  Immich because they already VPN into the home LAN via the road-warrior
  WireGuard; auto-backup works anywhere the tunnel is up.
  - *Operational caveat to document:* when a phone is on WireGuard,
    `immich.jardoole.xyz` must resolve to valen's **LAN** IP (home DNS pushed
    over the tunnel), or the public **AAAA** record sends it to Cloudflare where
    there is no inbound path (the known AAAA leak). Mitigation: ensure the WG
    profile pushes the home resolver, or set the mobile app's server URL to the
    LAN address / a name that resolves correctly over the tunnel. Verify during
    rollout.
- **Firewall:** no new inbound port — Immich rides valen's existing Traefik 443
  (loopback service). Update `docs/port-inventory.md` (drift-guarded).

## Monitoring

- Add `immich` to the `monitoring_blackbox_services` registry in
  `group_vars/monitoring/main.yml` (`kind: routed`, `immich.jardoole.xyz`,
  `preferred_ip_protocol: ip4`). **Required** — the
  `scripts/check-blackbox-coverage.py` pre-commit guard fails the build for any
  routed service missing from the registry.
- node_exporter, Alloy journald + Docker container logs, and the backup-freshness
  exporter cover Immich automatically (no per-service wiring).

## Layer ordering rationale

Immich sits in **applications**: it depends on every layer below — `ingress`
(Traefik/ACME), `service-infra` (Docker + Garage backup target), `storage` (the
pool for originals), and `auth` (Authentik OIDC live before OAuth config). The
`backup` layer runs after it (mirrors Immich's new buckets offsite), and
`monitoring` after that (scrapes it).

## Out of scope / follow-ups

- Public internet exposure (deliberately not done; WireGuard is the remote path).
- Fixing the AAAA leak (pre-existing, tracked in CLAUDE.md) — only relevant to
  the mobile DNS caveat above.
- External-library import of an existing on-disk photo tree (not needed; assets
  ingest via upload/mobile).
- WORM/immutability for the Immich DB (same deferred posture as the rest of the
  lab).
