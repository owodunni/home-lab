# Backup recovery testing

A backup you have never restored is a hypothesis, not a backup. This is the
log + procedure for periodically proving we can actually recover.

## What we back up

| Backup | What | Sidecar | Bucket (Garage) | Restore guide |
|---|---|---|---|---|
| Postgres DB | Authentik's database (users, apps, providers, flows…) | `pg-backup` (`eeshugerman/postgres-backup-s3`) | `authentik-backup` | [`restore_postgres.md`](restore_postgres.md) |
| File volumes | `media/`, `certs/`, `custom-templates/` | `volumes-backup` (`lobaro/restic-backup-docker`) | `authentik-volumes-backup` | [`restore_volumes.md`](restore_volumes.md) |

Both target the offsite Garage S3 on beelink (barn, over WireGuard), so a test
also exercises the offsite path end to end.

## Two kinds of drill

| Drill | What it proves | Risk | Cadence |
|---|---|---|---|
| [Quick drill](#quick-drill-non-destructive) | The newest dump/snapshot is readable and the data looks sane. | None — never touches the live service. | Before any significant change; quarterly. |
| [Full DR drill](#full-dr-drill-destructive) | An empty host + these buckets can be turned back into a working IdP. | Full SSO downtime; destroys live state. | Annually (or whenever you need real confidence). |

The quick drill checks the backups are *legible*. Only the full DR drill proves
the thing you actually care about: that you can **recover the running service**
from nothing.

### Codified commands

Two generic playbooks do most of this (any service, driven by its backup
manifest — see CLAUDE.md → "Backups: verify & restore"):

```bash
make verify-backups  SERVICE=authentik   # exist + fresh checks (the quick drill's core)
make restore-backups SERVICE=authentik   # in-place restore over the live service, typed-confirm prompt
```

`verify-backups` is the automated form of the freshness/existence checks below.
`restore-backups` performs an **in-place** restore (stop consumers → restore DB
+ volumes → bring the stack up); it does *not* wipe volumes. The full
destroy-and-rebuild-from-nothing drill below stays a deliberate manual procedure
— the point of it is to prove recovery when there is *nothing* to restore into.

## Quick drill (non-destructive)

Safe to run anytime — it must never risk the live service.

1. **Postgres** — run the *safe verification drill* in
   [`restore_postgres.md`](restore_postgres.md#safe-verification-drill-non-destructive).
   It restores the latest dump into a throwaway `authentik_verify` DB and checks
   row counts. Pass = restore completes clean + counts are sane.
2. **File volumes** — list snapshots and restore the latest into a host-mounted
   scratch dir (the sidecar's volume mounts are read-only and a `--rm`
   container's own fs is ephemeral, so bind-mount a dir to read back from),
   then spot-check the files:
   ```bash
   docker compose run --rm volumes-backup restic snapshots
   docker compose run --rm -v "$(pwd)/.restore-test:/restore" \
     volumes-backup restic restore latest --target /restore
   ls -R .restore-test/data && rm -rf .restore-test
   ```
3. **Freshness** — confirm the newest dump/snapshot is from within the expected
   schedule window (DB `@daily`, volumes `0 3 * * *`), i.e. not silently stale.
   `make verify-backups SERVICE=authentik` asserts this for both backups.
4. Record the run in the log below.

## Full DR drill (destructive)

This is the real test: destroy all live state, then rebuild the running service
from the offsite backups alone. **It is full SSO downtime** — everything that
authenticates through Authentik is offline until step 5 completes, so run it in
a maintenance window.

> **No safety net here by design.** This procedure assumes the live data is
> expendable (e.g. early setup, or you've accepted the loss). If there is data
> you cannot lose, take a local copy first — tar the `database` volume and
> `cp -a` the three bind-mount dirs — so you can roll back if recovery fails.

Run everything on the Authentik host (`pi-cm5-1`), from `/opt/authentik`. Use
`sudo` if the directory operations hit permission errors (the bind-mount dirs
may be root-owned).

### 1. Confirm there is a backup to restore *from*

Do not destroy anything until you've seen a dump and a snapshot:

```bash
docker compose exec pg-backup sh -c '. ./env.sh; aws $aws_args s3 ls "s3://$S3_BUCKET/$S3_PREFIX/"'
docker compose run --rm volumes-backup restic snapshots
```

You want at least one `authentik_<timestamp>.dump` and at least one restic
snapshot.

### 2. Simulate total loss

```bash
docker compose down -v                       # -v destroys the 'database' named volume
rm -rf media certs custom-templates
mkdir -p media certs custom-templates
```

### 3. Recover Postgres (DB before server — order matters)

```bash
docker compose up -d postgresql
docker compose ps                            # wait until postgresql is healthy
docker compose up -d pg-backup               # scheduler idles; container stays up so we can exec
docker compose exec pg-backup sh restore.sh  # restores latest dump into the fresh empty db
```

Use `exec`, **not** `run`: the image entrypoint ignores args, so
`run … restore.sh` would fire a *backup* instead of a restore (see
[`restore_postgres.md`](restore_postgres.md)). The container must already be
running. Do not start `server`/`worker` yet — if the server boots against an
empty DB it runs migrations and creates a schema that collides with the restore.

### 4. Recover the file volumes

Restore into a host-mounted scratch dir (the sidecar mounts the live volumes
read-only and a `--rm` container's fs is ephemeral), then copy back:

```bash
docker compose run --rm -v "$(pwd)/.restore:/restore" \
  volumes-backup restic restore latest --target /restore
cp -a .restore/data/media/.            ./media/
cp -a .restore/data/certs/.            ./certs/
cp -a .restore/data/custom-templates/. ./custom-templates/
rm -rf .restore
```

### 5. Bring up the full stack

`server` and `worker` start only now, against the already-restored DB:

```bash
docker compose up -d
docker compose ps
```

### 6. Verify recovery

```bash
# Data is really back:
docker compose exec postgresql psql -U authentik -d authentik -c \
  "select count(*) from authentik_core_user;  select count(*) from authentik_core_application;"
```

Then the real proof: open **auth.jardoole.xyz**, log in with your admin
account, and confirm your users / applications / flows are present. Pass = login
works and the counts are non-zero.

A successful run also proves `vault_authentik_restic_password` and the S3 keys
in your vault actually work — the scariest single points of failure, since
without the restic password no snapshot can ever be decrypted.

### 7. Record the run in the log below.

### Cadence

- Run the [quick drill](#quick-drill-non-destructive) **before any significant
  Authentik change** (e.g. before adding new providers/applications), and at
  least **quarterly** otherwise.
- Run the [full DR drill](#full-dr-drill-destructive) at least **once a year**.

## Test log

Newest first. Status: ✅ pass / ⚠️ pass with notes / ❌ fail.

| Date | Component(s) | Type | Result | Restored from | Notes / who |
|---|---|---|---|---|---|
| _YYYY-MM-DD_ | _Postgres / Volumes_ | _safe drill / full DR_ | _✅/⚠️/❌_ | _dump or snapshot id_ | _findings_ |

<!--
Example row:
| 2026-06-14 | Postgres + Volumes | safe drill | ✅ | authentik_2026-06-14T03:00:00.dump / snap a1b2c3 | 6 users, 4 apps restored clean. — alex |
-->
