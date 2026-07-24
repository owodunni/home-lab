# pi-cm5-1 root-fs headroom: image pruning, retention caps, apt clean

**Date:** 2026-07-24
**Status:** Approved, ready to implement

## Problem

pi-cm5-1 (monitoring stack + Authentik) sits at 48% root-fs usage (26 GB of
57 GB), and free space fell ~6.8 GB over the last 30 days
(`delta(node_filesystem_avail_bytes[30d])`). If the trend continued the host
would eventually fill its eMMC and take down Authentik — and with it SSO for
the whole lab.

Measured breakdown of the 26 GB (2026-07-24):

| Consumer | Size | Nature |
|---|---|---|
| containerd image store | 13.3 GB | **10.8 GB reclaimable** — 7 stacked Authentik image versions (2025.6→2026.5, ~1.8 GB each). Nothing prunes old images after upgrades, on any Docker host. |
| Prometheus TSDB | 4.1 GB | At its 30d retention cap as of ~2026-07-24 (oldest sample exactly 30d old) — stops growing here. |
| /usr | 4.4 GB | Static. |
| /var/swap | 2.0 GB | Static (Pi swapfile). |
| apt cache | 1.8 GB | `/var/cache/apt/archives` .debs. `APT::Periodic::AutocleanInterval` is already 7 (hifis role default) but autoclean only removes *superseded* .debs; these are current versions that only `apt-get clean` removes. |
| Docker volumes + misc | ~0.5 GB | Authentik data is small (324 MB of volumes). |
| Loki local | 2 MB | Chunks/index live in Garage S3 on valen, as designed. |

So the growth was **leaked Docker images from Authentik upgrades plus the TSDB
filling toward its cap** — not open-ended monitoring data. The same
image-leak pattern exists fleet-wide (valen lost 1.75 GB/30d and accumulates
*arr images); it just has ~200 GB free so nobody noticed.

## Decisions (user-confirmed)

- Automated pruning only — **no one-time manual prune**; the first timer run
  does the initial cleanup.
- Metrics retention stays **30d**; add a **size cap** as a hard safety.
- Log retention (Loki) rises to **90d** — long "go back in time" history lives
  on valen's pool, not the Pi eMMC.
- Authentik **stays on pi-cm5-1** (migration to pi-cm5-3 declined; disk
  pressure is solved by pruning and Authentik's own data is small).
- apt cache cleanup included.

## Design

### 1. Weekly Docker image prune timer (fleet-wide)

A systemd `docker-image-prune.service` (oneshot: `docker image prune -af`) +
`docker-image-prune.timer` (`OnCalendar=weekly`, `Persistent=true`,
`RandomizedDelaySec` so hosts don't all prune at once), deployed by
`playbooks/docker.yml` to `hosts: services` — every Docker host, so valen is
covered too. Templates live in `playbooks/templates/`; tunables
(schedule) in `group_vars/services/main.yml` per the no-role-defaults
convention. The geerlingguy.docker role is untouched.

Semantics: `docker image prune -af` removes only images referenced by **no**
container, so every running service's image survives. It operates on the
containerd image store (where these images actually live) exactly as on the
classic store. Trade-off, accepted: rolling back to a previous version
re-pulls from the registry instead of using a local copy — all images here
come from public registries.

No `--filter until=` age guard: `until` filters on image *build* time, not
pull time, so it would not protect a freshly pulled rollback image anyway
(old versions are built long ago by definition).

### 2. Prometheus TSDB size cap

`prometheus_storage_retention_size: "8GB"` in `group_vars/monitoring/main.yml`
next to the existing `prometheus_storage_retention: "30d"` (line 172). The
prometheus.prometheus collection role already templates this flag
(`--storage.tsdb.retention.size`, default "0" = disabled). 8 GB ≈ 2× the
observed 30d steady state, so it never triggers in normal operation; under a
cardinality explosion Prometheus drops oldest blocks instead of filling the
eMMC. Whichever of time/size trips first wins.

### 3. Loki retention 30d → 90d

`retention_period: 720h` → `2160h` in the Loki limits_config
(`group_vars/monitoring/main.yml:621`, compactor-driven deletion). Chunks and
index are in the Garage `loki` bucket on valen, so the extra ~2 months of logs
cost valen pool space (~3× current Loki bucket size at steady state), not Pi
eMMC. Verified the `loki` bucket is **not** in `backup_mirror_buckets`, so
this does not inflate beelink's additive offsite mirror.

### 4. apt cache clean

`unattended_clean_interval: 7` in `group_vars/all/main.yml` beside the other
`unattended_*` policy vars — sets `APT::Periodic::CleanInterval "7"` via the
existing hifis.toolkit.unattended_upgrades role, wiping
`/var/cache/apt/archives` weekly on all hosts (autoclean alone demonstrably
leaves 1.6 GB of current-version .debs).

## Non-goals

- Authentik migration to pi-cm5-3 (declined; revisit only if pi-cm5-1 shows
  instability).
- Remote/long-term metric storage (Thanos/Mimir to Garage) — YAGNI; the size
  cap plus 30d covers the actual risk. Raise Loki retention instead for
  outage archaeology.
- Pruning volumes/networks/build-cache (`docker system prune`) — volumes hold
  data; images are the only thing leaking.
- Offsite pruning or mirror changes.

## Verification

- `make precommit` passes.
- Operator applies: `make service-infra` (prune timer), `make monitoring`
  (Prometheus size cap + Loki retention), `make security` (apt clean).
- After the first timer firing: root fs on pi-cm5-1 drops to ~28%
  (`df -h /`), `docker image ls` shows only in-use images,
  `systemctl list-timers docker-image-prune.timer` shows the next run.
- Prometheus flags show `--storage.tsdb.retention.size=8GB`
  (`/api/v1/status/flags`); Loki config shows `retention_period: 2160h`.
