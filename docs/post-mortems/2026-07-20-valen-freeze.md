# Post-mortem: valen hard freeze, 2026-07-20

**Status:** Resolved (host power-cycled 2026-07-22 11:54; all services healthy).
**Severity:** High — the entire application platform was offline for ~55 hours.
**Author:** reconstructed from metrics + the frozen on-disk journal (see Evidence).

---

## Summary

At **2026-07-20 04:10:46 CEST** valen froze hard in the middle of its nightly
backup window. The kernel stopped scheduling normal work: user processes piled
into uninterruptible (`D`) sleep, the fork rate collapsed, and `systemd-journald`
stopped persisting — it left its active journal file dirty (renamed `…journal~`)
with a final timestamp of 04:10:46. The box kept answering ICMP and its Prometheus
exporters kept being scraped (they were already-running, resident processes), which
is why it looked "up" from the outside, but no new process could start — including
the per-connection SSH session service, so it was unreachable over SSH.

It stayed in that state until a person physically power-cycled it ~55 hours later.
Nothing auto-recovered.

## Impact

- **All valen-hosted services down ~55h**: Traefik (so every `*.jardoole.xyz`
  front door it routes), Garage S3, the full media/arr stack, Jellyfin, Jellyseerr.
- **Nextcloud down** fleet-wide even though it runs on a Pi — its file data is an
  NFS mount from valen's pool.
- **All backups stopped fleet-wide.** Garage S3 (the local backup target for every
  service) lives on valen, so no service could write a backup and the offsite
  mirror pull had nothing fresh to copy. Last good snapshots: postgres ~04:20
  07-20, config/data snapshots 07-19 (the 07-20 data run was mid-flight when the
  host froze). No data was lost; the gap is ~2 missed backup cycles.
- **No alerting reached the operator initially** beyond the raw Alertmanager fan-out
  (the operator was away); the incident was diagnosed remotely from metrics.

## Timeline (CEST)

| Time | Event |
|---|---|
| 07-19 20:52, 22:01 | Two planned reboots (the `dist-upgrade` from the security-layer work). Lab healthy afterwards. |
| 07-20 02:00–04:00 | Nightly backup window opens: postgres dumps (02:00), authentik volumes (03:00). Garage begins its nightly block **prune/resync** — thousands of `DELETE`/offload ops visible in the journal. |
| 07-20 **04:00** | **Three data-backup crons fire at once**: `nextcloud_data`, `vaultwarden_data`, `qbittorrent` (all `0 4 * * *`). Each restic-reads the pool and writes to Garage, whose store is on the *same* disk. |
| 07-20 04:10:46 | **Last journal entry.** journald's file is left dirty. System froze here. |
| 07-20 04:13–04:46 | Metrics: `D`-state procs spike 0 → 13 → 18; fork rate falls ~400→54/min and never recovers; disk I/O-time ≈ 0 throughout (tasks *waiting*, not doing I/O). |
| 07-20 04:22–05:01 | Containers/exporters die in a staggered wave as each touches the stalled FUSE mount. Purely-in-memory exporters (node/cadvisor/gpu) keep answering. |
| 07-20 → 07-22 | Host wedged; ICMP + resident exporters still respond, SSH refuses (can't spawn a session). ~55h outage. Operator away. |
| 07-22 11:54 | Physical power-cycle. Clean boot; all services auto-start and recover. |
| 07-22 ~13:00 | Confirmed healthy: 17 containers up, all probes green, storage responsive, disk SMART `PASSED`. Alertmanager silences removed. |

## Root cause

**Trigger:** an I/O convergence that saturated the single FUSE storage path.
Everything below funnels through **one** stack — `mergerfs` (FUSE, userspace) →
`dm-crypt`/LUKS → one 10.9 TB SATA disk (`sda`); the "pool" is currently a
single disk:

- 04:00: `nextcloud_data` + `vaultwarden_data` + `qbittorrent` restic snapshots
  fire simultaneously. restic walks the pool (reads) **and** uploads to Garage,
  whose object store is on the same pool (writes).
- Concurrently, Garage runs its nightly prune: thousands of block `DELETE` +
  resync/offload operations against that same disk.
- SnapRAID's full-pool sync+scrub is scheduled 04:30 on top of all this.

Under that concurrent load the FUSE (`mergerfs`) layer stopped making forward
progress; work piled into uninterruptible sleep waiting on the userspace daemon,
and the box livelocked. The near-zero disk *I/O-time* during the `D`-state spike is
the tell: the disk wasn't pegged — tasks were blocked in FUSE, not on the platter.

**Why it took the whole host down (not just storage):** `systemd-journald` was an
early casualty (its write path went through the stall), and once journald and the
init/cgroup machinery couldn't make progress, no new process could be forked. SSH
on this host is **socket-activated** (`ssh.socket` spawns a per-connection
`ssh@.service`); with forking wedged, the TCP handshake completed but the session
service never started — the exact "connection reset before banner" signature we
saw. This is a host-level hang, **not** an sshd or firewall misconfiguration.

**Ruled out:**
- *Failing disk* — SMART `PASSED`, 0 reallocated / 0 pending / 0 CRC, 990 power-on
  hours (~41 days old), 40 °C. No ATA resets or I/O errors in the kernel log.
- *OOM* — `node_vmstat_oom_kill` never incremented; MemAvailable *rose* as procs died.
- *The 2026-07-19 host firewall rollout* — ufw permitted SSH (handshake completed);
  the rollback timer is never enabled at boot; conntrack was ~100/262144. Not causal
  to the hang. (It did surface a *separate* chronic issue — see below.)

**Unprovable from available evidence:** the exact kernel-level mechanism (mergerfs
deadlock vs. soft-lockup vs. dm-crypt worker starvation). journald froze before any
hung-task trace or call stack was written, and valen has no serial console or
netconsole. The trigger workload and contributing architecture are well-supported;
the precise failing lock is not.

## Contributing factors

1. **Single spindle, single FUSE path, shared by everything.** Live service data,
   the Garage S3 *backup* store, and every restic *read* all contend on one disk
   through one userspace FUSE daemon. No I/O isolation between "serve" and "back up."
2. **Schedule convergence.** Three data backups at exactly `0 4`, Garage prune in the
   same window, SnapRAID at `04:30`. The crons were offset from *each other* in intent
   (comments say "02:00–05:00") but three still collide at 04:00, and none are
   isolated from the SnapRAID scan or the Garage prune.
3. **No auto-recovery.** No hardware/software watchdog to reset a livelocked host; no
   `Restart=` supervision that could have helped (moot once forking wedged, but there
   was no outer safety net at all).
4. **Observability blind spot.** Local journald froze *and* valen has never shipped
   logs to Loki (see `project-valen-no-loki-logs`). The only reason this was
   diagnosable was Prometheus metrics from resident exporters. A host can be wedged
   for 55h with our current stack and the logs say nothing.

## Secondary finding (not causal, worth fixing)

The frozen journal is flooded with `[UFW BLOCK]` drops of **container→host** traffic:
Docker containers (172.x on the compose bridges) connecting to `192.168.1.197:443`
(valen's own LAN IP) are dropped every ~20s. This is the split-horizon DNS path —
a container resolving `<svc>.jardoole.xyz` to valen's LAN IP and hitting the host's
443 — with no firewall allowance for the docker bridges to reach host 443. It didn't
cause the freeze, but it's constant log noise and means some container→service calls
only work by luck. Track separately.

## Remediation plan (proposed — not yet implemented)

Prioritised; each is a candidate for its own change + spec.

**P0 — make a wedged host recover itself**
- Enable a **hardware watchdog** (`systemd`'s `RuntimeWatchdog`/`watchdog-device`, or
  the mini-PC's Intel TCO WDT) so a livelocked kernel triggers a reset instead of a
  55h manual outage. This is the single highest-leverage fix: it converts "offline
  until someone drives over" into "self-reboots in minutes."

**P1 — de-risk the nightly I/O storm (the trigger)**
- **Stagger** the three `0 4` data backups (e.g. 04:00 / 04:20 / 04:40) and ensure
  SnapRAID (04:30) does not overlap the backup window at all.
- **Throttle** the heavy jobs: `restic --limit-upload`, and/or `IOSchedulingClass`
  (ionice idle) + `CPUWeight` on the SnapRAID and Garage-prune units so backup/maint
  I/O can never starve live serving.
- Consider decoupling the **Garage prune** from the backup window entirely.

**P2 — reduce shared-path fragility**
- Evaluate moving the **Garage S3 store off the mergerfs/FUSE pool** onto the NVMe
  (or a plain ext4 mount), so the *backup target* doesn't contend with live pool I/O
  through FUSE. Biggest structural improvement; needs a data-migration plan.
- Revisit whether restic backups of pool data must read *through* mergerfs or can read
  the underlying branch directly.

**P3 — close the observability gap**
- Fix **Alloy on valen** so it actually ships to Loki (`project-valen-no-loki-logs`).
- Add a **per-host log-ingestion freshness alert** (no host has shipped in N minutes)
  — this would have flagged valen days before the freeze.
- Add a **host-level liveness alert** that fires on the *pattern* seen here (fork rate
  floored / `D`-state processes sustained high / node_exporter scrape gaps) rather
  than relying on a full `InstanceDown`, which never triggered because the exporter
  stayed resident.

**P4 — secondary**
- Add a firewall allowance (or fix the resolution path) for the container→host:443
  `[UFW BLOCK]` noise.

## Verification / recovery state (2026-07-22)

- valen booted 11:54; `ssh.service` active (normal daemon this boot), storage mount
  responsive, disk SMART `PASSED`.
- 17 containers running; Traefik `:443`, Garage `127.0.0.1:3900`, NFS `:2049/:111`
  all listening; all blackbox probes green; all valen Prometheus targets UP.
- Alertmanager silences (created during the incident, would have expired 07-30)
  **removed** — alarms fully re-enabled.
- **Backups are still stale (57–80h)** and `BackupLocalStale` / `BackupMirrorStale`
  correctly fire; they will clear after the next successful backup cycle (nightly),
  or run `make` backups manually to clear sooner. This is a true condition, not noise.

## Evidence appendix

- Frozen journal: `/var/log/journal/*/system@0006573021bbfb42-8236be7947bd8ae6.journal~`,
  mtime 07-20 04:11, last entry 04:10:46, read via
  `journalctl --file … --since '2026-07-20 03:55'`.
- Metrics (Prometheus, retained): `node_procs_blocked` 0→18 at 04:16–04:46;
  `rate(node_forks_total[10m])` ~400→54/min; `node_disk_io_time_seconds_total` ≈0;
  `node_vmstat_oom_kill` flat at 0; `up{instance="valen:9633"}` → 0 at 04:43.
- Schedules: `group_vars/{nextcloud,vaultwarden,qbittorrent}/main.yml`
  (`0 4 * * *`), `group_vars/storage/main.yml` (`snapraid_runner_schedule 04:30`).
- Health now: `smartctl -H -A /dev/sda` PASSED; `docker ps` 17 running; `ss -ltnp`.
