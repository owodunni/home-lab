# Restoring the Immich Postgres database (restic, built-in dump)

Unlike every other Postgres service in this lab, Immich's DB backup is **not**
a hand-rolled `pg_dump` sidecar — it is Immich's own **built-in scheduled
backup** (Administration -> Settings -> Backup), which writes
`UPLOAD_LOCATION/backups/immich-<ts>.sql.gz`. Two sidecars in
`roles/immich/templates/docker-compose.yml.j2` turn that into a restic-backed
restore point:

- **`immich-unpack`** (`debian:bookworm-slim`) polls for the newest `.sql.gz`
  and gunzips it to a plain `{{ immich_dir }}/db-dump/immich.sql`, atomic
  temp-then-rename, but **only** when the source `.sql.gz` is younger than
  `immich_unpack_freshness_window_hours` (the freshness guard — see
  group_vars/immich/main.yml).
- **`db-backup`** (`lobaro/restic-backup-docker`) snapshots that file to the
  Garage S3 repo `s3:…/immich-postgres-backup` on `immich_db_backup_schedule`,
  with `--skip-if-unchanged` so a stalled built-in dump job stops producing
  new snapshots (rather than a fresh-but-stale snapshot every night) —
  eventually tripping `BackupLocalStale`.

This is the manifest's `type: restic` entry named `db-dump` — **not**
`type: postgres`. That is deliberate: Immich's own dumper is version-matched to
its schema/VectorChord extensions, so we let it produce the dump and only
restic-restore-the-file; there is no custom `pg_restore` engine for it. Loading
the restored `.sql` into a live Postgres is the manual runbook below.
Originals (`library/`, `upload/`, `profile/`) are restored separately — that
is the manifest's `originals` entry, plain file copy-back, no runbook needed.

All commands run on the Immich host (valen), from `{{ immich_dir }}`
(`/opt/immich`).

## Step 1 — restic-restore the dump (codified)

```bash
make verify-backups  SERVICE=immich   # lists every db-dump restore point + asserts freshness
make restore-backups SERVICE=immich   # restic-restores db-dump (+ originals) back onto disk

# Roll the DB dump back to an OLDER snapshot — pick an id from verify-backups:
make restore-backups SERVICE=immich TARGETS='db-dump=ab12cd34'
```

This only gets the plain `immich.sql` back onto disk at
`{{ immich_dir }}/db-dump/immich.sql` (via the shared `restic` restore
handler — see `roles/backup_restore/tasks/restic.yml`). It does **not** load
it into Postgres; that is Step 2.

## Step 2 — load the dump into Postgres (manual, destructive)

> ⚠️ This overwrites the live Immich database. Only do this for a real
> recovery, a deliberate full DR drill, or the safe verification drill below
> (which never touches production).

Immich's documented CLI restore transforms one line before loading (Immich
backup/restore docs, "Restore via Command Line"):

```bash
# 1. Stop the consumers so nothing is writing mid-restore
docker compose stop immich-server immich-machine-learning

# 2. Transform + load. On a FRESH database (server has never run since the
#    containers were created) or with DB_SKIP_MIGRATIONS=true set in .env:
sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  db-dump/immich.sql \
  | docker compose exec -T database psql --dbname="${DB_DATABASE_NAME}" --username="${DB_USERNAME}" \
      --single-transaction --set ON_ERROR_STOP=on

# 3. Bring Immich back up
docker compose start immich-server immich-machine-learning
```

`--single-transaction --set ON_ERROR_STOP=on` means the DB is never left
half-restored: either the whole dump applies or nothing does.

### Recovering onto a fresh host

1. Deploy the applications layer as normal (`make applications` is blocked
   here — the operator runs it). Postgres comes up and auto-creates the empty
   `immich` DB + role from `DB_DATABASE_NAME`/`DB_USERNAME`.
2. `make restore-backups SERVICE=immich` (Step 1 above) to get `immich.sql`
   and the originals back onto disk.
3. Run Step 2's load command against the fresh, never-started DB.
4. `.env` (DB password, backup S3 keys, restic password) is templated from
   vault, so it is recreated by the playbook — nothing to restore there.

## Safe verification drill (non-destructive)

Immich has no separate "scratch database" tooling like `createdb`/`dropdb`
against its own image (the `database` service is Immich's custom
pgvector/VectorChord postgres image, not a plain `postgres:16` client), so the
lowest-risk drill is Immich's own **restore-from-backup UI flow** against a
disposable second instance, or simply:

```bash
# Restore the latest db-dump snapshot to a scratch dir and inspect it
docker compose run --rm -v "$(pwd)/.restore-test:/restore" \
  db-backup restic restore latest --target /restore

# Sanity-check it decompresses/parses as SQL (no full load needed to prove
# the snapshot itself is intact)
head -n 20 .restore-test/data/db-dump/immich.sql
wc -l .restore-test/data/db-dump/immich.sql

rm -rf .restore-test
```

A full load-and-verify drill (matching `docs/backup-recovery-testing.md`'s
depth for the other services) requires a throwaway Immich stack pointed at a
scratch `DB_DATA_LOCATION` — not yet automated here; record any manual drill
result in `docs/backup-recovery-testing.md`.

## Notes

- The DB restic repo lives in its own bucket (`immich-postgres-backup`); the
  originals repo uses a **separate** bucket (`immich-data-backup`) and key
  pair. Both repos share one encryption password
  (`vault_immich_restic_password`).
- Restic encrypts every repo — without `vault_immich_restic_password` no
  snapshot can ever be decrypted. Store a copy outside this repo.
- Database backups contain metadata only, not photos/videos — they must be
  paired with the `originals` restore (see the manifest entry in
  `group_vars/immich/main.yml`).
