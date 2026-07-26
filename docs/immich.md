# Immich (self-hosted photos)

Self-hosted photo/video management for the household (`immich.jardoole.xyz`),
replacing Google Photos — the last major service in the effort to leave Google.
Runs on **valen** (compute + Postgres + originals all co-located: Intel iGPU for
ML/transcoding, NVMe for the DB, the MergerFS pool for bulk originals), behind
the co-located Traefik, with **Authentik native OIDC SSO**, vault-encrypted
secrets, and the standard 3-2-1 backup path. No new internet exposure — remote
access is **WireGuard/VPN only**.

Full design rationale: `docs/superpowers/specs/2026-07-25-immich-deployment-design.md`.
Vendor references used while building this: `immich-sso.md`,
`immich-docker-compose.yml` (repo root, the upstream compose the role is based on).

- Playbook: `playbooks/immich.yml` (imported by the `applications` layer)
- Role: `roles/immich/`
- Config: `group_vars/immich/{main,vault}.yml`
- Inventory group: `[immich]` -> `valen`
- URL: `https://immich.jardoole.xyz` (loopback `127.0.0.1:2283`, Traefik-proxied)
- DB restore runbook: `docs/restore_immich_db.md`

## Architecture

| Concern | Where |
|---|---|
| App (immich-server, immich-machine-learning, redis/valkey, database) | `valen`, `/opt/immich` (Ansible-authored compose) |
| Bulk originals (`library/`, `upload/`, `profile/`, thumbs, encoded video) | MergerFS pool, `{{ mergerfs_mount_point }}/immich` (SnapRAID-parity-protected) |
| Postgres data (`DB_DATA_LOCATION`) | valen local **NVMe**, `/opt/immich/postgres` — **never** the pool/NFS |
| GPU (transcode + ML) | Intel iGPU via `/dev/dri` passthrough + `group_add` from the `media_gpu` fact — shared with Jellyfin |
| Web UI | loopback `127.0.0.1:2283`, proxied by Traefik at `immich.jardoole.xyz` |
| TLS | Traefik wildcard cert (`*.jardoole.xyz`), `certResolver: letsencrypt` |
| Auth | Immich **native OAuth2/OIDC** against Authentik — **not** forward-auth (see "SSO") |
| DB backup | Immich built-in dump -> `immich-unpack` (gunzip) -> `db-backup` (restic) -> Garage `immich-postgres-backup` |
| Originals backup | `data-backup` (restic, excludes thumbs/encoded-video/backups) -> Garage `immich-data-backup` |
| Remote access | WireGuard/VPN only — no internet-facing port beyond the existing Traefik 443 |

### Why valen (not a Pi + NFS)

Immich's Postgres uses pgvector/VectorChord with `--data-checksums`, and Postgres
over a network filesystem is a documented corruption/locking footgun — so the DB
must be local. Co-locating on valen keeps compute, the Intel iGPU (ML + QuickSync
transcode), the local NVMe DB, and the bulk originals on the pool all on one host,
with plain bind mounts and no NFS round-trip for the DB. The iGPU is now shared
three ways (Jellyfin transcode, Immich transcode, Immich ML) — accepted for
household load. Drawback: browsing spins the HDD pool up (spin-down latency on the
first gallery/thumbnail hit); acceptable for household use.

### Why Immich's built-in DB dump (not a hand-rolled pg_dump sidecar)

Unlike every other Postgres service in this lab, Immich's DB is backed up by
**Immich's own built-in scheduled backup** (Administration -> Settings -> Backup),
which writes `UPLOAD_LOCATION/backups/immich-<ts>.sql.gz`. Its dumper is
version-matched to Immich's schema and VectorChord/pgvector extensions and
maintained upstream, so it keeps working across upgrades — no risk of our own
`pg_dump` flags drifting from what those extensions need. This is deliberately
**not** a new `postgres` backup engine: two sidecars turn that `.sql.gz` into a
normal restic restore point:

- **`immich-unpack`** polls for the newest `.sql.gz` and gunzips it to a plain
  `/opt/immich/db-dump/immich.sql` (atomic temp-then-rename), but **only** when the
  source is younger than `immich_unpack_freshness_window_hours` (26h). Unpacking to
  plain `.sql` lets restic's content-defined chunking dedup across nightly
  snapshots (~a delta/night vs. a full copy of a re-gzipped file).
- **`db-backup`** (restic) snapshots that file with `--skip-if-unchanged`, so a
  stalled built-in dump job stops advancing the snapshot and trips
  `BackupLocalStale` — instead of restic writing a fresh-but-stale snapshot forever
  green. (The freshness guard has real teeth only because of this flag; requires
  restic >=0.17, and the pinned lobaro image bundles 0.18.0.)

The restore — loading the plain `.sql` into a live Postgres — is a documented
**manual runbook** (`docs/restore_immich_db.md`), not a custom `pg_restore` engine.

### Why two independent restic repos

The DB dump and the originals get their **own** Garage bucket + key pair each
(`immich-postgres-backup`, `immich-data-backup`), sharing one encryption password
(`vault_immich_restic_password`). Neither snapshot is atomic with the other —
acceptable for a personal library: the worst case is a handful of very recent
photos on disk but not yet in the restored DB, and those are re-scannable. Both
repos are mirrored offsite to beelink by the `backup` layer.

## Secrets to generate

Before the first run, create `group_vars/immich/vault.yml` (`uv run
ansible-vault create group_vars/immich/vault.yml`, see the `vault` skill) with
these `vault_immich_*` vars. Formats aren't arbitrary — the Garage keys are a
hard format Garage's import validates against:

| Variable | Format | Generate with | Used for |
|---|---|---|---|
| `vault_immich_db_password` | any strong random string | `openssl rand -base64 32` | Postgres password (`DB_PASSWORD`) |
| `vault_immich_restic_password` | 32 bytes, base64 — repo-wide convention | `openssl rand -base64 32` | Encrypts **both** restic repos (DB + originals). Losing it makes every existing snapshot unrecoverable — store a copy outside this repo |
| `vault_immich_db_backup_s3_access_key` | Garage: `GK` + 24 hex | `scripts/garage-keygen.sh vault_immich_db_backup_s3` (prints both halves as ready-to-paste YAML) | DB-dump restic repo's Garage key (bucket `immich-postgres-backup`) |
| `vault_immich_db_backup_s3_secret_key` | Garage: 64 hex | (same command as above) | pairs with the access key above |
| `vault_immich_data_backup_s3_access_key` | Garage: `GK` + 24 hex | `scripts/garage-keygen.sh vault_immich_data_backup_s3` | Originals restic repo's Garage key (bucket `immich-data-backup`) — **must be a separate key pair** from the DB one |
| `vault_immich_data_backup_s3_secret_key` | Garage: 64 hex | (same command as above) | pairs with the access key above |
| `vault_immich_oauth_client_id` | from Authentik | (set on the Authentik provider) | Immich OIDC client ID — **pasted into Immich's Admin UI**, not consumed by any template (Immich has no env-var OAuth path) |
| `vault_immich_oauth_client_secret` | from Authentik | (set on the Authentik provider) | Immich OIDC client secret — same, pasted into the Admin UI |

Don't hand-roll the Garage key pairs — `scripts/garage-keygen.sh` produces the
exact format Garage's import validates against (see the `garage-keys` skill). The
OAuth pair is generated on/for the Authentik provider (see "SSO"); it lives in
vault as the single source of truth even though no template consumes it, so a
rotation or rebuild has one place to look.

## First deploy

Four things need a human before/around the first run — **I cannot do these**:

1. **DNS (AdGuard split-horizon).** The `adguard_rewrites` entry mapping
   `immich.jardoole.xyz` -> `valen.jardoole.xyz` is already in
   `group_vars/adguard/main.yml`. If AdGuard hasn't picked it up yet, redeploy it
   so LAN/VPN clients resolve Immich to valen directly (not the public Cloudflare
   record):

   ```bash
   make app service=adguard
   ```

   No Cloudflare/UniFi change is needed — Immich is loopback-only behind the
   existing Traefik 443, reached over the LAN or WireGuard, never exposed publicly.

2. **Authentik provider** (OAuth2/OpenID Connect, via the `authentik-app` skill):
   - Set the provider's **Client ID** / **Client Secret** to
     `vault_immich_oauth_client_id` / `vault_immich_oauth_client_secret`.
   - Redirect URIs (Strict / Authorization):
     - `app.immich:///oauth-callback`
     - `https://immich.jardoole.xyz/auth/login`
     - `https://immich.jardoole.xyz/user-settings`
   - Bind an **Immich Users** group so only family accounts can authenticate.

3. **Garage buckets/keys** — provisioned automatically by the first play in
   `playbooks/immich.yml`, as long as the vault vars above are set first.

4. **Deploy, then pick up the new buckets downstream.** The system layer (GPU
   facts on valen) is already satisfied.

   ```bash
   make app service=immich       # runs playbooks/immich.yml
   make backup                   # offsite mirror picks up the two new buckets
   make monitoring               # blackbox front-door probe + backup-freshness
   ```

Then, **post-deploy in the Immich web UI**:

- **Enable the built-in DB backup** (Administration -> Settings -> Backup) — the
  whole `db-dump` -> `immich-unpack` -> `db-backup` chain depends on it writing
  `.sql.gz` files. If its schedule is changed from the default (daily), bump
  `immich_unpack_freshness_window_hours` in `group_vars/immich/main.yml` to match
  (with slack) — that value cannot see the UI setting.
- **Paste the OAuth config** (Administration -> Settings -> OAuth Authentication):
  - Issuer URL: `https://auth.jardoole.xyz/application/o/<slug>/`
  - Client ID / Secret: `vault_immich_oauth_client_id` / `_secret`
  - Auto-register ON; keep local password login enabled until OAuth **including
    the mobile app** is verified end-to-end, then disable password login.

## SSO — Authentik native OIDC (not forward-auth)

Immich is deliberately **not** behind the Authentik forward-auth middleware (same
reasoning as Jellyfin; unlike the *arr apps). Forward-auth intercepts every
request with a browser SSO redirect, which the **native Immich mobile app cannot
follow** — it would break background photo backup. Immich authenticates against
Authentik with its own native OAuth2/OIDC client instead, configured in the Immich
Admin UI (there is no env-var OAuth path — see `immich-sso.md`). An Authentik
outage blocks interactive OIDC login but, with local password login kept as a
fallback, never locks you out of the library.

## Google Photos migration

Immich's own **CLI bulk-upload** (or the mobile app's backup) imports each
person's existing library. Rough cut-over:

1. Verify SSO + mobile-app backup work end-to-end for each family member.
2. Bulk-import each Google Photos export (Google Takeout) — ~100GB (Alex) + ~100GB
   (wife) migrating in, ceiling ~1TB over the next few years, which is why
   originals live on the 11TB pool, not valen's NVMe.
3. Enable phone auto-backup so new photos land in Immich going forward, then retire
   Google Photos once confident.

## Backups

Both backups are restic snapshots to Garage (local on valen, mirrored offsite to
beelink by the `backup` layer) with the same grandfather-father-son retention
every service in this lab uses. Media *library* files elsewhere aren't backed up,
but Immich originals **are** — they're not re-acquirable.

```bash
make verify-backups  SERVICE=immich   # exist + fresh? + restic check + list every restore point
make drill           SERVICE=immich   # non-destructive: prove both restores work
make restore-backups SERVICE=immich   # DESTRUCTIVE: restic-restore latest of each (typed confirm)
```

| Backup | Engine | Bucket | Schedule |
|---|---|---|---|
| `db-dump` | Immich built-in dump -> unpack -> restic | `immich-postgres-backup` | `0 6 * * *` |
| `originals` | restic of `library`/`upload`/`profile` (excludes thumbs/encoded-video/backups) | `immich-data-backup` | `0 7 * * *` |

**Restoring an older snapshot** — pass `TARGETS` with short-IDs from
`make verify-backups`:

```bash
make restore-backups SERVICE=immich TARGETS='db-dump=ab12cd34,originals=ef56ab78'
```

> The `db-dump` restore only puts the plain `immich.sql` back on disk — loading it
> into a live Postgres is a **manual runbook** (`docs/restore_immich_db.md`),
> because Immich's dump must be transformed (`search_path`) and loaded against its
> custom pgvector/VectorChord image. Database backups are metadata only, not
> photos — always pair a DB restore with the `originals` restore.

## Maintenance

- **Upgrades**: bump `immich_version` in `group_vars/immich/main.yml` to a newer
  tag (https://github.com/immich-app/immich/releases), re-run
  `make app service=immich`. Review each release's notes for breaking changes and
  confirm fresh backups (`make verify-backups SERVICE=immich`) beforehand — Immich
  runs DB migrations on startup.
- **TLS**: served by Traefik's wildcard cert — no action as long as Traefik keeps
  renewing.
- **Rotating secrets**: edit `group_vars/immich/vault.yml`
  (`uv run ansible-vault edit …`) and re-run the playbook. **Never** change
  `vault_immich_restic_password` without migrating the repos — it makes existing
  snapshots unrecoverable.
- **Logs**: `cd /opt/immich && docker compose logs -f <service>` (e.g.
  `immich-server`, `immich-machine-learning`, `immich-unpack`, `immich-db-backup`).
- **Adding a routed service reminder**: a new `*.jardoole.xyz` name needs an
  `adguard_rewrites` entry + `make app service=adguard`, or LAN/VPN clients resolve
  its public Cloudflare record. See CLAUDE.md "DNS resolution".
