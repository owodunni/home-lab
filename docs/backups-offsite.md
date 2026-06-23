# Offsite backups: the 3-2-1 mirror

This documents the offsite half of the backup strategy — how the mirror works,
how to restore from it, and the one-time cutover/decommission steps. For the
local verify/restore tooling (`make verify-backups` / `make restore-backups`),
see `CLAUDE.md` → "Backups" and the `/backups` skill.

## How it fits together

```
copy 1 — LIVE          copy 2 — LOCAL                  copy 3 — OFFSITE
(primary data)         (restic in Garage S3 on VALEN)  (plain restic repos on BEELINK)

service sidecars ─────► s3.jardoole.xyz (→ valen) ──rclone pull (read-only)──► /mnt/storage/restic-offsite/<bucket>
                          one bucket per backup          backup-mirror.timer (06:00 daily)
```

- **Local copy** — each service's restic / pg-dump sidecar writes snapshots to a
  bucket in valen's Garage. This is fast (LAN-local) and has no dependency on the
  offsite link.
- **Offsite copy** — `[backup_mirror]` (beelink, at the barn) runs
  `backup-mirror.timer`, which `rclone copy`s every bucket in
  `backup_mirror_buckets` (group_vars/backup_mirror/main.yml) into
  `{{ backup_mirror_dest }}/<bucket>`. Because rclone copies the encrypted
  objects byte-for-byte, each destination dir **is** a valid restic repo.
- **Additive, not a mirror** — we use `rclone copy --immutable --checksum`, *not*
  `sync`. Copy never deletes on the destination, so a `restic forget --prune`, an
  accidental wipe, or ransomware on valen is **never** propagated offsite — the
  offsite keeps snapshots valen has already forgotten and becomes a longer-
  retention tier. `--immutable` refuses to overwrite an existing object (restic
  packs are write-once, so this also trips loudly on tampering); `--checksum`
  verifies transfers by hash. The cost is growth (see "Pruning" below).

### Why pull + read-only (the security model)

- beelink uses a **read-only** Garage key (granted by `playbooks/backup-mirror.yml`),
  and **initiates** the connection. So:
  - a compromised **valen** has no credential or path to beelink → cannot touch
    the offsite copy;
  - a compromised **beelink** cannot delete or alter valen's copy (read-only), and
    the objects it can read are restic-encrypted — it never holds the restic
    password, so no plaintext leaks.
- Neither single-node compromise destroys both copies.

## Restore from the offsite copy (beelink)

The mirror dir is a normal restic repo. You only need the **service's restic
password** (the same `vault_<service>_restic_password` the sidecar uses — it is
*not* stored on beelink). On beelink:

```bash
# List restore points (example: Authentik DB repo).
sudo RESTIC_PASSWORD='<service restic password>' \
  restic -r /mnt/storage/restic-offsite/authentik-backup/restic snapshots

# Restore a snapshot to a scratch dir, then move the files/dump where needed.
sudo RESTIC_PASSWORD='<service restic password>' \
  restic -r /mnt/storage/restic-offsite/authentik-backup/restic \
  restore latest --target /tmp/restore-authentik-db
```

Notes:
- The `/restic` subpath applies to repos that use it (Authentik/Nextcloud/
  Vaultwarden **DB** repos — see each `RESTIC_REPOSITORY` in the role's
  `docker-compose.yml.j2`). Volume/data and the *arr config repos sit at the
  bucket root, so drop the `/restic` suffix for those.
- A DB repo holds the `*.dump`; restore it, then `pg_restore` into a fresh
  Postgres as in `docs/restore_postgres.md`.
- This is the break-glass path for when valen is gone. When valen is healthy,
  prefer `make restore-backups SERVICE=<svc>` (restores from the local copy).

## One-time cutover (operator)

1. **Vault:** create `host_vars/valen/vault.yml` with `vault_garage_rpc_secret`
   and `vault_garage_admin_token`; create `group_vars/backup_mirror/vault.yml`
   with the read-only mirror key (`scripts/garage-keygen.sh vault_backup_mirror_s3`).
2. Run `make service-infra` to stand up Garage on valen.
3. **Flip DNS:** point `s3.jardoole.xyz` at valen's LAN IP (192.168.1.197). The
   wildcard cert (DNS-01) already covers valen, so TLS is unaffected. Do this
   *after* step 2 so sidecars never hit an empty endpoint.
4. Re-run the app layers so each service's bucket/key is provisioned on valen and
   the sidecars start writing locally.
5. Run `make backup` to grant the read-only key and deploy the mirror on beelink.

## Decommission the old beelink Garage

History is a fresh start (we did not migrate old snapshots). Keep beelink's old
Garage running **read-only** as a fallback until the new local+offsite copies
have built up a comfortable retention window, then:

- remove `zorun.garage` from beelink (it is no longer in `[garage]`),
- drop the stale `s3.jardoole.xyz` Traefik route on beelink,
- reclaim the old Garage bucket storage on beelink's pool.

## Verifying the mirror

- Freshness is alerted automatically: the sync script writes
  `backup_mirror_last_success_timestamp_seconds` to the node_exporter textfile
  dir, and the `BackupMirrorStale` / `BackupMirrorRunFailed` alert rules
  (group_vars/monitoring/main.yml) email if the offsite copy goes stale or a run
  fails.
- Manually: `uv run ansible backup_mirror -a "ls -la /mnt/storage/restic-offsite"`
  (read-only) and `journalctl -u backup-mirror` on beelink.
- **Integrity / bit-rot**: beelink's `snapraid_runner` timer scrubs the pool
  daily (the offsite repos live on it), detecting and repairing silent
  corruption; `SnapraidScrubStale`/`SnapraidScrubErrors` alert if it stops.
  `rclone --checksum` verifies each transfer. Logical repo integrity is asserted
  by `make verify-backups` (`restic check`) and `make drill` against the local
  side.
- **Offsite restore drill** — `make offsite-drill [SERVICE=<svc>]` is the offsite
  analogue of `make local-drill`: it runs restic **on your workstation**, reaches
  each mirrored repo on beelink over **SFTP**, and for every backup lists
  snapshots, runs `restic check`, restores the latest snapshot to a scratch dir,
  and asserts the result (non-destructive). restic decrypts only on the
  workstation, so this proves the offsite copy restores **without** installing
  restic on beelink or putting the restic password there. Run it periodically and
  log it in `docs/backup-recovery-testing.md`. (It reads the repos as the SSH
  login user, which the `backup_mirror` role enables by making
  `{{ backup_mirror_dest }}` world-readable — encrypted packs only.)

## Pruning the offsite (bounding growth)

Because the pull is additive, the offsite keeps every snapshot ever copied,
including ones valen has pruned locally — so it grows. This is intentional
(longer retention, ransomware depth), and growth is slow thanks to restic dedup
and watched by the `HighDiskUsage` alert on beelink. When you do need to reclaim
space, prune **deliberately** (never as an automated job with delete rights):

```bash
# From the SERVICE's host (it holds the restic password), point restic at the
# offsite repo over SFTP and apply the same GFS policy, then prune:
restic -r sftp:beelink:/mnt/storage/restic-offsite/<bucket>[/restic] \
  forget --keep-daily 7 --keep-weekly 4 --keep-monthly 4 --keep-yearly 1 --prune
```

Do this rarely and only after confirming the local + offsite copies are healthy.

## Residual risk & immutability (#5)

The offsite has **no WORM/immutability**. The pull model means a compromised
*valen* can't reach beelink at all, and `--immutable` blocks overwrites — but a
compromised beelink **host** (root) or physical loss/theft of beelink endangers
the offsite copy itself. That is an accepted residual: it costs you only the
offsite copy — the primary data and valen-local backup survive — so it is not a
data-loss event on its own.

The recommended upgrade for true immutability (and a second provider/geo) is a
small **Backblaze B2 bucket with Object-Lock** holding just the crown-jewel DBs
(Vaultwarden, Nextcloud, Authentik — all tiny). It was considered and deferred;
revisit it if the threat model changes. A filesystem switch on beelink (ZFS/btrfs
snapshots) was rejected — root can still destroy snapshots, so it does not close
this gap.
