# Backup recovery testing

A backup you have never restored is a hope, not a backup. This is the cadence
for proving the fleet's backups are fresh, intact, and restorable — the "0
errors" of 3-2-1-1-0 — plus a log of drills actually run.

See also: `CLAUDE.md` → "Backups", the `/backups` skill, `docs/backups-offsite.md`
(offsite mirror + restore-from-beelink), `docs/restore_postgres.md`,
`docs/restore_volumes.md`.

## The three levels

| Command | Destructive? | Proves | Suggested cadence |
|---|---|---|---|
| `make verify-backups SERVICE=<g>` | no | a fresh snapshot exists **and** `restic check` passes (repo integrity) | weekly, per service |
| `make drill SERVICE=<g>` | no | the latest snapshot actually **restores** (files recovered / dump parses) | monthly, rotating services |
| `make restore-backups SERVICE=<g>` | **yes** (typed confirm) | full DR — restore over the live stack | on a real incident, or a deliberate annual full-DR exercise |

Automated, no human needed (already running): the offsite mirror freshness alert
(`BackupMirrorStale`), SnapRAID sync+scrub with bit-rot alerts
(`SnapraidScrubStale`/`SnapraidSyncGuardTripped`), and `rclone --checksum` on the
pull. The `verify`/`drill` make targets stay operator-run because they need
Ansible + the vault password, which we deliberately keep out of a scheduler; run
them from your workstation on the cadence above (a personal cron invoking them
with the vault password is fine, but that is a separate trust decision).

## What `make drill` does

For each entry in the service's `backups:` manifest it restores the **latest**
snapshot into a scratch dir and asserts the result, then deletes the scratch — it
never stops the stack, overwrites live volumes, or loads into the live DB:

- **restic / volumes** — restores into `<compose_dir>/.drill` and asserts files
  were recovered.
- **postgres** — restores the dump and validates it with `pg_restore --list`
  (parses the archive TOC; no DB connection).

To also exercise the **offsite** copy, run a manual restic restore from beelink
(see `docs/backups-offsite.md` → "Restore from the offsite copy") and log it below.

## Drill log

Record each drill so gaps are visible. Newest first.

| Date | Service(s) | Command | Source (local/offsite) | Result | Notes |
|---|---|---|---|---|---|
| _(none yet — add the first entry after running a drill)_ | | | | | |
