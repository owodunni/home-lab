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

## Post-deploy verification (run once after standing the strategy up)

After a fresh cutover (Garage on valen + the offsite mirror on beelink), walk
these in order — each proves a different copy/property. Steps 1–5 are the
must-do confidence checks; step 6 proves the design and is worth doing once.

1. **Local copy exists, fresh, intact** — the foundation.
   ```bash
   uv run ansible garage -b -a "garage bucket list"        # buckets exist on valen
   make verify-backups SERVICE=authentik                   # fresh + restic check passes
   ```
   Repeat `verify-backups` for `vaultwarden` and `nextcloud`. ✅ lists restore
   points, asserts freshness, prints "restic check passed".

2. **Offsite copy pulled to beelink.**
   ```bash
   uv run ansible backup_mirror -a "ls -la /mnt/storage/restic-offsite"
   uv run ansible backup_mirror -a "systemctl list-timers backup-mirror.timer"
   uv run ansible backup_mirror -a "cat /var/lib/node_exporter/backup_mirror.prom"
   ```
   ✅ a subdir per bucket, timer armed for 06:00, recent
   `backup_mirror_last_success_timestamp_seconds`. To verify now instead of
   waiting for 06:00: `uv run ansible backup_mirror -b -a "systemctl start backup-mirror.service"`.

3. **Offsite is independently restorable** (needs only the service restic
   password, which is *not* stored on beelink):
   ```bash
   uv run ansible backup_mirror -b \
     -a "env RESTIC_PASSWORD='<svc restic pw>' restic -r /mnt/storage/restic-offsite/authentik-backup/restic snapshots"
   ```
   ✅ lists snapshots — copy 3 restores even if valen is gone.

4. **Restore drill** — proves the data is usable, not just present.
   ```bash
   make drill SERVICE=authentik
   ```
   ✅ restores latest to scratch, asserts, cleans up; live stack untouched. Log
   it below.

5. **Integrity automation armed** (on hosts with parity — beelink today):
   ```bash
   uv run ansible backup_mirror -a "systemctl list-timers 'snapraid*'"
   uv run ansible backup_mirror -a "cat /var/lib/node_exporter/snapraid.prom"
   ```
   ✅ `snapraid-runner.timer` armed (04:30), recent sync/scrub timestamps,
   `snapraid_sync_delete_guard_tripped 0`.

6. **Prove the two design properties** (one-time):
   - *Delete non-propagation* — make a throwaway snapshot on valen, `restic
     forget --prune` it, run the mirror, confirm the pruned packs **still exist**
     offsite (the point of `rclone copy`).
   - *Read-only key* — `uv run ansible garage -b -a "garage bucket info authentik-backup"`
     shows `backup-mirror-ro` with **read** only on every bucket.

Expected non-failures: valen has no SnapRAID parity yet, so step 5 only shows
activity on beelink and valen-origin data (Nextcloud files) is 2-1 until its
parity drive lands.

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
