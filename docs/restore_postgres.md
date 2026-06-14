# Restoring the Authentik Postgres database (pg-backup)

The `pg-backup` sidecar (`roles/authentik/templates/docker-compose.yml.j2`) takes
a periodic logical dump of the Authentik Postgres database and uploads it to the
offsite Garage S3 bucket (`authentik-backup`, on beelink at the barn, reached
over WireGuard). This is the **only** backup of the database — the Postgres data
dir itself is deliberately *not* in the restic volumes backup (a raw copy of a
live data dir is crash-inconsistent; the logical dump is the correct capture).

File volumes (`media/`, `certs/`, `custom-templates/`) are restored separately —
see [`restore_volumes.md`](restore_volumes.md).

All commands run on the Authentik host, from `{{ authentik_dir }}`
(`/opt/authentik`).

## Image reference: `eeshugerman/postgres-backup-s3`

So we don't have to re-read the upstream README, here is how the image behaves
(tag `:16`, pinned to match the Postgres 16 major in the compose file):

- **Entrypoint** runs `backup.sh`. With `SCHEDULE` set (we use `@daily`) it hands
  off to `go-cron` and the container stays up running the dump on schedule. With
  `SCHEDULE` empty it would run one dump and exit. Because our container is
  long-running you drive ad-hoc actions with `docker compose exec`, not `run`.
- **Backup** = `pg_dump --format=custom` (custom format is already compressed),
  optionally GPG-encrypted if `PASSPHRASE` is set (it is **not**, see
  `authentik_backup_passphrase_enabled` in `group_vars/authentik/main.yml`).
- **Object key**: `s3://$S3_BUCKET/$S3_PREFIX/${POSTGRES_DATABASE}_<ISO8601>.dump`
  → for us: `s3://authentik-backup/pg/authentik_2026-06-14T03:00:00.dump`
  (`.dump.gpg` if encryption were on).
- **Restore** = `pg_restore --clean --if-exists` into the existing database.
  **It is destructive**: every database object is dropped and re-created from the
  dump. The *database itself* must already exist (our compose creates the
  `authentik` DB + role automatically the first time the empty volume starts).
- **Retention**: `BACKUP_KEEP_DAYS` (we set 7) prunes dumps older than N days
  from the bucket after each run.
- **Custom endpoint**: it talks to Garage (not AWS) via `$S3_ENDPOINT`; the
  scripts pass `--endpoint-url` automatically through `env.sh`'s `$aws_args`.
- **Gotcha**: "latest" is found with a single `aws s3 ls`, so if the bucket ever
  exceeds 1000 objects the newest dump may not be selected — pass an explicit
  timestamp in that case. (At 7-day retention this won't happen.)

### Manual commands on the running sidecar

```bash
# List the dumps in the bucket (newest last) — sanity-check freshness
docker compose exec pg-backup sh -c \
  '. ./env.sh; aws $aws_args s3 ls "s3://$S3_BUCKET/$S3_PREFIX/"'

# Trigger an ad-hoc dump right now
docker compose exec pg-backup sh backup.sh
```

## Restore into production (destructive — real disaster recovery)

> ⚠️ This **overwrites the live `authentik` database**. Only do this for a real
> recovery, or as a deliberate full DR drill. For a routine "can we recover?"
> check, use the **safe verification drill** below instead — it never touches
> production.

```bash
# 1. Stop the consumers so they aren't holding connections / writing mid-restore
docker compose stop server worker

# 2a. Restore the latest dump
docker compose exec pg-backup sh restore.sh

# 2b. ...or a specific dump by its timestamp (from the `aws s3 ls` above)
docker compose exec pg-backup sh restore.sh 2026-06-14T03:00:00

# 3. Bring Authentik back up
docker compose start server worker
```

### Recovering onto a fresh host

On a rebuilt host the Postgres volume starts empty, so:

1. Deploy the auth layer as normal (`make authentik` is blocked here — the
   operator runs it). Postgres comes up and auto-creates the empty `authentik`
   DB + role from `POSTGRES_DB`/`POSTGRES_USER`.
2. Run the production restore steps above to load the dump into that empty DB.
3. Restore the file volumes ([`restore_volumes.md`](restore_volumes.md)).

The `.env` (secret key, PG password, S3 creds) is templated from vault, so it is
recreated by the playbook — nothing to restore there.

## Safe verification drill (non-destructive)

This restores the latest dump into a throwaway database (`authentik_verify`) on
the same Postgres instance and inspects it, without touching the live
`authentik` DB. This is what you run to **test the backup** (see
[`backup-recovery-testing.md`](backup-recovery-testing.md)).

```bash
docker compose exec pg-backup sh -euxc '
  . ./env.sh

  # Newest dump key in the bucket
  KEY=$(aws $aws_args s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" | sort | tail -n1 | awk "{print \$4}")
  echo "Restoring: $KEY"
  aws $aws_args s3 cp "s3://$S3_BUCKET/$S3_PREFIX/$KEY" /tmp/verify.dump

  # Fresh scratch DB (drop any leftover from a previous drill)
  dropdb   --if-exists -h "$POSTGRES_HOST" -U "$POSTGRES_USER" authentik_verify
  createdb             -h "$POSTGRES_HOST" -U "$POSTGRES_USER" authentik_verify

  # Restore into the scratch DB
  pg_restore --no-owner --clean --if-exists \
    -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d authentik_verify /tmp/verify.dump

  # Liveness checks — tables present, and core data has rows
  psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d authentik_verify -c "\dt" | head -n 20
  psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d authentik_verify \
    -c "SELECT count(*) AS users    FROM authentik_core_user;" \
    -c "SELECT count(*) AS apps     FROM authentik_core_application;" \
    -c "SELECT count(*) AS providers FROM authentik_providers_oauth2_oauth2provider;"

  # Clean up
  dropdb -h "$POSTGRES_HOST" -U "$POSTGRES_USER" authentik_verify
  rm -f /tmp/verify.dump
'
```

A passing drill = the restore completes with no errors and the counts look
sane (non-zero users, your expected number of applications/providers). Record
the result in [`backup-recovery-testing.md`](backup-recovery-testing.md).

## Notes

- `pg-backup` and the restic `volumes-backup` use **separate** Garage buckets and
  key pairs so their retention/lifecycle are independent.
- If at-rest encryption is ever enabled (`PASSPHRASE`), restore needs the same
  passphrase — losing it makes the dumps unrecoverable. Store it outside this
  repo.
</content>
</invoke>
