# Restoring Authentik file volumes (restic)

The `volumes-backup` sidecar (`roles/authentik/templates/docker-compose.yml.j2`)
backs up `media/`, `certs/`, and `custom-templates/` to Garage S3 via restic.
Postgres is backed up the same way (a `pg_dump` captured in restic) and restored
separately via the `db-backup`/`pg-dump` sidecars — see
[`restore_postgres.md`](restore_postgres.md).

> **Codified path:** `make restore-backups SERVICE=authentik` runs this
> (and the Postgres restore) for you, behind a typed confirmation prompt — see
> [`backup-recovery-testing.md`](backup-recovery-testing.md). The manual steps
> below are the reference for what it does and for one-off / partial restores.

## Prerequisites

Run all commands on the Authentik host, from `/opt/authentik` (or
`{{ authentik_dir }}` if changed).

## List available snapshots

```bash
docker compose run --rm volumes-backup restic snapshots
```

## Restore everything (latest snapshot)

The sidecar mounts the live volumes **read-only**, and a `--rm` container's own
filesystem is thrown away, so we restore into an explicitly bind-mounted host
dir (`.restore`) that survives the container and can be read back from the host.

```bash
# 1. Stop services that read these volumes
docker compose stop server worker

# 2. Restore into a host-mounted scratch dir (restic recreates the original
#    source paths, so files land under .restore/data/<path>)
docker compose run --rm -v "$(pwd)/.restore:/restore" \
  volumes-backup restic restore latest --target /restore

# 3. Copy restored data back into place
cp -a .restore/data/media/.            ./media/
cp -a .restore/data/certs/.            ./certs/
cp -a .restore/data/custom-templates/. ./custom-templates/

# 4. Clean up and restart
rm -rf .restore
docker compose start server worker
```

## Restore a specific snapshot or path

```bash
# Specific snapshot ID (from `restic snapshots`)
docker compose run --rm -v "$(pwd)/.restore:/restore" \
  volumes-backup restic restore <snapshot-id> --target /restore

# Just one directory
docker compose run --rm -v "$(pwd)/.restore:/restore" \
  volumes-backup restic restore latest --target /restore --include /data/media
```

## Notes

- `redis/` and the Postgres data dir are **not** in this backup — see
  `group_vars/authentik/main.yml` for why.
- Restic encrypts the repo with `vault_authentik_restic_password`. Without
  it, snapshots cannot be decrypted — there is no recovery if it's lost.
