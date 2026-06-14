# Restoring Authentik file volumes (restic)

The `volumes-backup` sidecar (`roles/authentik/templates/docker-compose.yml.j2`)
backs up `media/`, `certs/`, and `custom-templates/` to Garage S3 via restic.
Postgres is restored separately via the `pg-backup` sidecar — see
[`restore_postgres.md`](restore_postgres.md).

## Prerequisites

Run all commands on the Authentik host, from `/opt/authentik` (or
`{{ authentik_dir }}` if changed).

## List available snapshots

```bash
docker compose run --rm volumes-backup restic snapshots
```

## Restore everything (latest snapshot)

```bash
# 1. Stop services that read these volumes
docker compose stop server worker

# 2. Restore into a temp dir
docker compose run --rm volumes-backup restic restore latest --target /tmp/restore

# 3. Copy restored data back into place
cp -a /tmp/restore/data/media/. ./media/
cp -a /tmp/restore/data/certs/. ./certs/
cp -a /tmp/restore/data/custom-templates/. ./custom-templates/

# 4. Restart
docker compose start server worker
```

## Restore a specific snapshot or path

```bash
# Specific snapshot ID (from `restic snapshots`)
docker compose run --rm volumes-backup restic restore <snapshot-id> --target /tmp/restore

# Just one directory
docker compose run --rm volumes-backup restic restore latest --target /tmp/restore --include /data/media
```

## Notes

- `redis/` and the Postgres data dir are **not** in this backup — see
  `group_vars/authentik/main.yml` for why.
- Restic encrypts the repo with `vault_authentik_restic_password`. Without
  it, snapshots cannot be decrypted — there is no recovery if it's lost.
