---
name: backups
description: How this home lab's generic backup verify/restore tooling works. Use when verifying or restoring a service's backups, reading or editing a service's `backups:` manifest in group_vars, working with the restic/postgres backup engines, restoring a non-latest snapshot (the TARGETS map), or adding support for a new backup engine.
---

# Backups: verify & restore

Backup *verification* and *restore* are codified as two generic playbooks that
work for **any** service, driven by a per-service manifest. There are no
service-specific backup playbooks.

```bash
make verify-backups  SERVICE=authentik   # non-destructive: exist + fresh? + list restore points
make restore-backups SERVICE=authentik   # DESTRUCTIVE: typed-confirm prompt; restores latest
make restore-backups SERVICE=authentik \
  TARGETS='postgres=ab12cd34,volumes=ef56ab78'  # roll specific backups to an OLDER snapshot
```

## Restic everywhere → one retention policy for DBs and volumes

Every backup is a **restic** snapshot, so databases and file volumes get the
*same* grandfather-father-son retention and the *same* restore semantics:

- **File volumes** — a restic sidecar snapshots the bind-mounted dirs directly.
- **Databases** — a small client sidecar writes a logical dump (`pg_dump -Fc`)
  to a shared volume; a restic sidecar snapshots that dump. So the DB rides
  restic's retention and per-snapshot restore exactly like the volumes, instead
  of a flat "keep N days" that loses the only good copy after the window.

Retention is GFS via `restic forget` (`--keep-daily/-weekly/-monthly/-yearly
… --prune`) set per repo in `group_vars/<service>/main.yml`.

## Selecting a snapshot (the TARGETS map)

Because every snapshot the policy keeps is independently restorable,
`verify-backups` **lists every restore point** (snapshot ID + timestamp) and
`restore-backups` accepts a `TARGETS` map to restore something other than the
newest:

```bash
make restore-backups SERVICE=authentik TARGETS='postgres=7f9e0a1b,volumes=ef56ab78'
```

- The **name** (`postgres`, `volumes`) is the entry's `name:` in the service's
  `backups:` manifest — *not* a hostname or compose service.
- The **snapshot id** is a restic short-ID, taken from `make verify-backups`
  (or `docker compose exec <sidecar> restic snapshots` on the host).
- Any backup you omit — or omitting `TARGETS` entirely — restores its **latest**
  snapshot. Internally each handler reads
  `backup_targets[backup.name] | default('latest')`.
- The repos are **independent**: there is no single cross-backup point-in-time.
  For a coherent rollback, pick the snapshot closest to the same timestamp in
  each repo.

## How it fits together

Three pieces, separated by what changes when:

1. **Manifest (per service)** — `backups:` in `group_vars/<service>/main.yml`. A
   list with one entry per backup, each tagged with a `type` (engine) plus the
   fields that engine needs. Also `backup_compose_dir` and
   `backup_consumer_services` (the compose services to stop during a restore).
   *This is the only thing that changes when a service gains/moves a backup.*
2. **Type handlers (per engine)** — `roles/backup_verify/tasks/<type>.yml` and
   `roles/backup_restore/tasks/<type>.yml`. Each knows how to verify / restore
   *one* engine (`postgres`, `restic`, …). *Written once per engine, shared by
   every service that uses it.* Both current engines store snapshots in restic:
   `restic` restores by copying paths back over the live volume, `postgres`
   restores by `pg_restore` of the dump from the chosen snapshot — so `postgres`
   *verifies* via the shared restic verifier (snapshot freshness) and only its
   *restore* differs.
3. **Playbooks (generic)** — `playbooks/verify-backups.yml` and
   `playbooks/restore-backups.yml`. They target `hosts: {{ backup_service }}`
   (so the service's group_vars load), then the role loops the manifest and
   `include_tasks: "{{ backup.type }}.yml"` to dispatch each entry to its
   handler. *These never change.*

This is dispatch **per backup type**, composed **per service**: a service with a
Postgres dump *and* a restic volume snapshot *and* (later) a MySQL dump is
handled by the same two commands, each entry routed to its engine.

The live reference for the manifest schema is the commented `backups:` list in
[`group_vars/authentik/main.yml`](../../../group_vars/authentik/main.yml).

## How a restore works

`restore-backups.yml` is the executable form of the
[full DR drill](../../../docs/backup-recovery-testing.md): it (1) halts on an
interactive `vars_prompt` until the operator types the exact service name —
deliberately *not* an `-e` flag, so it can't fire from shell history; (2) stops
`backup_consumer_services` so nothing reads/writes mid-restore; (3) runs each
per-type restore handler — each lists the available restore points, restic
restores the snapshot named in `backup_targets[<name>]` (default `latest`), then
the `restic` handler copies paths back over the live volume while the `postgres`
handler `pg_restore`s the dump into the live DB; (4) brings the whole stack up
again. It is destructive and interactive by design — it cannot run unattended.

## Adding a new backup type

To support a new engine (e.g. `mysql`, `mongodb`):

1. Add `roles/backup_verify/tasks/<type>.yml` — given the loop var `backup` (one
   manifest entry), **fail the play** if a usable, fresh backup is missing;
   otherwise stay green. Keep it non-destructive (read-only listing).
2. Add `roles/backup_restore/tasks/<type>.yml` — given `backup`, restore the
   snapshot named in `backup_targets[backup.name] | default('latest')` over the
   live service (and list the available restore points first). Assume consumers
   are already stopped.
3. Document the manifest fields your handler reads (mirror the comments on the
   existing `postgres`/`restic` entries).

That's it — no playbook or Makefile edits. A service opts in by adding a
manifest entry of that `type`.

## Per-service restore guides

Service-specific, copy-pasteable restore/verification steps live under `docs/`,
e.g. [`docs/restore_postgres.md`](../../../docs/restore_postgres.md),
[`docs/restore_volumes.md`](../../../docs/restore_volumes.md), and the drill log in
[`docs/backup-recovery-testing.md`](../../../docs/backup-recovery-testing.md).
