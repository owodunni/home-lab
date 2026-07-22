# Host resilience: self-heal + crash capture — design

**Date:** 2026-07-22
**Status:** Approved for implementation
**Follows:** [`docs/post-mortems/2026-07-20-valen-freeze.md`](../../post-mortems/2026-07-20-valen-freeze.md)

## Context

On 2026-07-20 valen froze in a **partial livelock** during its nightly backup
window: tasks stuck in uninterruptible `D`-state on the single FUSE/LUKS pool
path, while ICMP + resident exporters kept answering and ~54 forks/min limped
on. It stayed wedged **~55 hours** until a hand power-cycle. Two failures made a
storage stall into a 55h platform outage:

1. **No self-recovery.** valen has an `iTCO_wdt` hardware watchdog but systemd
   was not petting it (`RuntimeWatchdogUSec=0`). Worse, because the freeze was
   *partial* (PID 1 likely kept running), even a plain armed watchdog might not
   have fired — systemd would have kept petting it.
2. **No trace.** journald (userspace) froze at 04:10:46 and never persisted the
   hang; valen has no serial console, netconsole, or kdump. The root cause is
   therefore **unconfirmed** — a new kernel `6.12.95`, docker/containerd
   upgrades, and ufw all landed hours earlier, and we cannot rank them without a
   stack trace of the stuck tasks.

The root cause cannot be fixed until it is *known*. This spec does not attempt to
fix it. It makes the host **recover itself in minutes** and **capture the trace**
so the next occurrence (tonight or later) is diagnosable — the disciplined
"recover + diagnose before you fix" step. Load-staggering (P1), the kernel
question, and the Alloy/Loki gap (P3) are explicit fast-follows, not in scope
here.

## Goals / non-goals

**Goals**
- A wedged host reboots itself in ~1–3 min instead of staying down for hours.
- A `D`-state hang produces a kernel stack trace that survives the reboot.
- Fleet-wide, reproducible in Ansible, and **applicable live tonight without
  rebooting valen** (so it protects the next 04:00 window immediately).

**Non-goals (deferred)**
- Reducing the nightly backup I/O convergence (P1).
- Rolling back / bisecting kernel 6.12.95 (waits for a captured trace).
- Fixing Alloy/Loki log shipping and adding log-ingestion alerts (P3).
- kdump full vmcore capture (heavier; pstore's dmesg tail should suffice first).
- netconsole live off-box streaming (needs a collector + a ufw hole; only if a
  real pstore capture turns out truncated).

## Design

A single inline-task function playbook `playbooks/host-resilience.yml`
(`hosts: all`, matching the `wifi.yml` convention), imported into the **system**
layer (base-OS/hardware state, alongside GPU drivers and Pi firmware). All tuning
lives in `group_vars/all/main.yml` per the repo's no-role-defaults rule.

### 1. Self-heal — reboot on hang (the "plausible fix")

`/etc/sysctl.d/60-host-resilience.conf`, applied live (`sysctl --system`) and
persisted:

| sysctl | value | why |
|---|---|---|
| `kernel.hung_task_panic` | `1` | A task stuck in `D`-state past the timeout → **kernel panic**. This is what catches the *partial* livelock the watchdog can miss — it targets the exact signature we saw. |
| `kernel.hung_task_timeout_secs` | `120` | Kernel default. A task uninterruptible for 120s straight is genuinely abnormal even under heavy I/O, so spurious-panic risk is low. |
| `kernel.panic` | `30` | Auto-reboot 30s after any panic (otherwise a panicked box just sits there). |
| `kernel.panic_on_oops` | `1` | Treat an oops like a panic (capture + reboot) instead of limping in an undefined state. |

(`kernel.hung_task_all_cpu_backtrace` is deliberately left off: it prints a large
all-CPU dump *before* the panic, which can push the faulting task's own backtrace
out of pstore's limited tail. The single hung-task report — which names the stuck
syscall / FS layer — prints immediately before the panic and is the datum we need.)

**Chosen deliberately over a plain hardware watchdog alone:** the operator has
accepted an auto-reboot. Because the freeze was a partial livelock, panic-on-hang
is the mechanism that reliably converts it into a recovery; the watchdog below is
the backstop for a *total* freeze.

### 2. Self-heal backstop — hardware watchdog

`/etc/systemd/system.conf.d/10-watchdog.conf` → `RuntimeWatchdogSec=60`, activated
with `systemctl daemon-reexec` (no reboot needed). systemd pets `/dev/watchdog0`;
if PID 1 itself wedges (total freeze), the `iTCO_wdt`/`bcm2835` chip resets the
host in ~60s. The Pis already run this (60s); this standardises the fleet and
closes valen's gap.

### 3. Capture the trace — pstore

**pstore is the whole tonight capture path, and it is already wired.** valen has
pstore mounted with the `efi_pstore` backend, EFI vars present, and
`systemd-pstore.service` **already enabled**. On panic the kernel writes the dmesg
tail (the hung-task backtrace + the panic) into EFI variables that **survive the
reboot**; `systemd-pstore` then archives those records to
`/var/lib/systemd/pstore/` on the next boot and frees the limited EFI-var space.
So the *only* missing piece for capture is a panic to trigger it — which §1's
`hung_task_panic` supplies. The role just asserts pstore is mounted and
`systemd-pstore` enabled fleet-wide (a no-op on valen). After a recurrence:
`ls /var/lib/systemd/pstore/`.

*Caveat:* EFI-var pstore keeps the *tail* of dmesg (a few tens of KB) — which is
exactly the panic + faulting task, so it is sufficient here. A very long dump could
truncate; that is what the deferred netconsole path below would cover.

**netconsole — deferred to fast-follow (not tonight).** A live off-box UDP stream
of kernel messages to the monitoring Pi would capture the *full* untruncated dump,
but it needs (a) a `socat` collector service on pi-cm5-1, (b) a **hole in
pi-cm5-1's default-deny ufw** for the UDP port, and (c) a pinned target MAC. That
surface is not worth it while pstore already captures the trace with zero new
infrastructure. Revisit only if a real pstore capture proves truncated. When done,
the sender is generic: `netconsole=@/,<port>@192.168.1.19/2c:cf:67:fb:d1:83` (blank
src lets the kernel pick the egress dev by route).

### 4. Don't let recovery hide recurrence

A silent self-reboot must not mask a recurring problem. Two low-cost signals:
- The pstore archive on disk is the durable record (checked after any reboot).
- **Fast-follow (P3, not tonight):** a Prometheus alert on an unexpected
  `node_boot_time_seconds` reset, so an auto-reboot pages.

## Deployment / tonight

Everything applies **without rebooting valen**: sysctls via `sysctl --system`,
watchdog via `systemctl daemon-reexec`, `systemd-pstore` via
`systemctl enable --now`. Apply with:

```
uv run ansible-playbook playbooks/host-resilience.yml
```

(Optionally `--limit valen` first, then fleet-wide.) A 3-line live stopgap can arm
the panic sysctls immediately if the playbook can't be run before 04:00.

## Verification

- `sysctl kernel.hung_task_panic kernel.panic` → `1`, `30` on every host.
- `systemctl show -p RuntimeWatchdogUSec` → `1min` on valen (was `0`).
- `systemctl is-enabled systemd-pstore` → enabled; `/sys/fs/pstore` mounted.
- **End-to-end (optional, disruptive — maintenance window only):**
  `echo c > /proc/sysrq-trigger` forces a panic; confirm valen reboots on its own
  within ~30s and a record lands in `/var/lib/systemd/pstore/` + the netconsole
  log. Not part of the tonight rollout.

## Risks

- **Spurious panic** under an unusually long but progressing I/O stall
  (`>120s` in `D`). Judged low; a 120s uninterruptible wait is abnormal. If it
  bites, raise `hung_task_timeout_secs` or drop `hung_task_panic` (keep the
  watchdog).
- **Masking effect:** auto-reboot could hide a recurring hang if no one checks
  pstore — mitigated by the durable on-disk archive now and the boot-reset alert
  (P3) next.
