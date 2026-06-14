# Restoring the Authentik Postgres database (restic)

The Authentik database is backed up as a **logical dump captured in a restic
repo**, so it gets the same grandfather-father-son retention and
restore-any-snapshot behaviour as the file volumes. Two sidecars in
`roles/authentik/templates/docker-compose.yml.j2` do this:

- **`pg-dump`** (`postgres:16-alpine`, pinned to the Postgres 16 major) writes a
  `pg_dump --format=custom` of the `authentik` DB to the shared `db-dump` volume
  as `/dump/authentik.dump`, on a schedule (immediately on start, then every
  `authentik_db_dump_interval_seconds`). It writes to a temp file and atomically
  renames, so a snapshot never captures a half-written dump.
- **`db-backup`** (`lobaro/restic-backup-docker`) snapshots that volume to the
  offsite Garage S3 repo `s3:…/authentik-backup/restic` (beelink at the barn,
  over WireGuard) on `authentik_db_backup_schedule`, then applies the GFS
  `restic forget` policy in `authentik_db_backup_retention_args`.

This is the **only** backup of the database — the Postgres data dir itself is
deliberately *not* in any restic backup (a raw copy of a live data dir is
crash-inconsistent; the logical dump is the correct capture). File volumes
(`media/`, `certs/`, `custom-templates/`) are restored separately — see
[`restore_volumes.md`](restore_volumes.md).

All commands run on the Authentik host, from `{{ authentik_dir }}`
(`/opt/authentik`).

## Codified restore (preferred)

The generic tooling restores the DB (and the volumes) for you, behind a typed
confirmation prompt:

```bash
make verify-backups  SERVICE=authentik   # lists every DB restore point + asserts freshness
make restore-backups SERVICE=authentik   # restores the LATEST DB snapshot (+ volumes)

# Roll the DB back to an OLDER good state — pick a snapshot ID from verify-backups:
make restore-backups SERVICE=authentik TARGETS='postgres=ab12cd34'
```

Under the hood the `postgres` restore handler
(`roles/backup_restore/tasks/postgres.yml`) restic-restores the chosen snapshot
to a scratch dir, then runs `pg_restore --clean --if-exists --no-owner` of the
dump into the live `authentik` DB through the `pg-dump` sidecar (which already
carries the DB connection env). The restore playbook stops `server`/`worker`
first and brings the whole stack back up after.

## Manual commands on the running sidecars

```bash
# List the DB snapshots (newest last) — sanity-check freshness / find an ID
docker compose exec db-backup restic snapshots

# Force a fresh dump now (pg-dump dumps on start), then a snapshot on its cron;
# to snapshot immediately, run the lobaro backup entrypoint:
docker compose restart pg-dump
docker compose exec db-backup backup
```

## Restore into production manually (destructive — real disaster recovery)

> ⚠️ This **overwrites the live `authentik` database**. Only do this for a real
> recovery or a deliberate full DR drill. For a routine "can we recover?" check,
> use the **safe verification drill** below — it never touches production.

```bash
# 1. Stop the consumers so they aren't holding connections / writing mid-restore
docker compose stop server worker

# 2. Restore the chosen snapshot's dump to a host-mounted scratch dir
#    (restic recreates the source path, so it lands at .restore/data/authentik.dump)
docker compose run --rm -v "$(pwd)/.restore:/restore" \
  db-backup restic restore latest --target /restore     # or <snapshot-id> instead of latest

# 3. pg_restore it into the live DB via the pg-dump sidecar (carries PG* env)
docker compose run --rm --no-deps -v "$(pwd)/.restore:/restore" \
  --entrypoint sh pg-dump -c \
  'pg_restore --clean --if-exists --no-owner -d "$PGDATABASE" /restore/data/authentik.dump'

# 4. Clean up and bring Authentik back up
rm -rf .restore
docker compose start server worker
```

### Recovering onto a fresh host

On a rebuilt host the Postgres volume starts empty, so:

1. Deploy the auth layer as normal (`make authentik` is blocked here — the
   operator runs it). Postgres comes up and auto-creates the empty `authentik`
   DB + role from `POSTGRES_DB`/`POSTGRES_USER`.
2. Run the production restore steps above (or `make restore-backups`) to load the
   dump into that empty DB. `--clean --if-exists` is harmless on an empty DB.
3. Restore the file volumes ([`restore_volumes.md`](restore_volumes.md)).

The `.env` (secret key, PG password, S3 creds, restic password) is templated
from vault, so it is recreated by the playbook — nothing to restore there.

## Safe verification drill (non-destructive)

This restores the latest dump into a throwaway database (`authentik_verify`) on
the same Postgres instance and inspects it, without touching the live
`authentik` DB. This is what you run to **test the backup** (see
[`backup-recovery-testing.md`](backup-recovery-testing.md)).

```bash
# 1. Restore the latest DB snapshot's dump to a host-mounted scratch dir
docker compose run --rm -v "$(pwd)/.restore-test:/restore" \
  db-backup restic restore latest --target /restore-test

# 2. Restore that dump into a fresh scratch DB and check it — via the pg-dump
#    sidecar, which has the PG* connection env and pg client tools.
docker compose run --rm --no-deps -v "$(pwd)/.restore-test:/restore" \
  --entrypoint sh pg-dump -euxc '
    dropdb   --if-exists -h "$PGHOST" -U "$PGUSER" authentik_verify
    createdb             -h "$PGHOST" -U "$PGUSER" authentik_verify
    pg_restore --no-owner --clean --if-exists \
      -h "$PGHOST" -U "$PGUSER" -d authentik_verify /restore/data/authentik.dump
    psql -h "$PGHOST" -U "$PGUSER" -d authentik_verify -c "\dt" | head -n 20
    psql -h "$PGHOST" -U "$PGUSER" -d authentik_verify \
      -c "SELECT count(*) AS users     FROM authentik_core_user;" \
      -c "SELECT count(*) AS apps      FROM authentik_core_application;" \
      -c "SELECT count(*) AS providers FROM authentik_providers_oauth2_oauth2provider;"
    dropdb -h "$PGHOST" -U "$PGUSER" authentik_verify
  '

# 3. Clean up the scratch dir
rm -rf .restore-test
```

A passing drill = the restore completes with no errors and the counts look
sane (non-zero users, your expected number of applications/providers). Record
the result in [`backup-recovery-testing.md`](backup-recovery-testing.md).

## Notes

- The DB restic repo lives under the `restic/` subpath of the `authentik-backup`
  bucket; the file-volumes repo uses a **separate** bucket
  (`authentik-volumes-backup`) and key pair. Both repos share one encryption
  password (`vault_authentik_restic_password`).
- Restic encrypts every repo — without `vault_authentik_restic_password` no
  snapshot can ever be decrypted. Store a copy outside this repo.
