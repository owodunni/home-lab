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

## How to run a test

Do this as a **non-destructive drill** — it must never risk the live service.

1. **Postgres** — run the *safe verification drill* in
   [`restore_postgres.md`](restore_postgres.md#safe-verification-drill-non-destructive).
   It restores the latest dump into a throwaway `authentik_verify` DB and checks
   row counts. Pass = restore completes clean + counts are sane.
2. **File volumes** — list snapshots and restore the latest into a temp dir, then
   spot-check the files:
   ```bash
   docker compose run --rm volumes-backup restic snapshots
   docker compose run --rm volumes-backup restic restore latest --target /tmp/restore-test
   ls -R /tmp/restore-test/data && rm -rf /tmp/restore-test
   ```
3. **Freshness** — confirm the newest dump/snapshot is from within the expected
   schedule window (DB `@daily`, volumes `0 3 * * *`), i.e. not silently stale.
4. Record the run in the log below.

### Cadence

- Run a drill **before any significant Authentik change** (e.g. before adding
  new providers/applications), and at least **quarterly** otherwise.
- Do a full destructive DR drill (restore over production, or restore onto a
  scratch host) at least **once a year**.

## Test log

Newest first. Status: ✅ pass / ⚠️ pass with notes / ❌ fail.

| Date | Component(s) | Type | Result | Restored from | Notes / who |
|---|---|---|---|---|---|
| _YYYY-MM-DD_ | _Postgres / Volumes_ | _safe drill / full DR_ | _✅/⚠️/❌_ | _dump or snapshot id_ | _findings_ |

<!--
Example row:
| 2026-06-14 | Postgres + Volumes | safe drill | ✅ | authentik_2026-06-14T03:00:00.dump / snap a1b2c3 | 6 users, 4 apps restored clean. — alex |
-->
</content>
