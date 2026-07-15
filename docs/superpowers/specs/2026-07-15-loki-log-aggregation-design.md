# Loki log aggregation & log-based alerting — design

**Date:** 2026-07-15
**Status:** Approved, ready to implement
**Layer:** monitoring

## Problem

The metrics stack (Prometheus + node_exporter + cAdvisor + blackbox) detects a
host down, a container down, or a front door that stops answering. It does **not**
see a service that is *up and answering* but malfunctioning internally. The
motivating incident: Jellyseerr's container stayed `Up` and its Traefik front door
kept returning HTTP, while the application was silently failing every outbound
request with a DNS resolution error (`EAI_AGAIN` / `getaddrinfo`). No metric moved;
the only evidence was in the container's **logs**.

Part 2 (blackbox front-door probes) was honestly assessed as unable to catch this
class of failure. This is the log layer that can: aggregate every container's and
host's logs centrally, and alert on fatal patterns as they appear.

## Goal

1. Aggregate logs from every fleet host — Docker container logs and host journald —
   into a central, queryable store.
2. Alert on high-signal fatal log patterns (starting with the DNS-resolution class
   that caused the Jellyseerr outage) via the **existing** Alertmanager → email.
3. Make logs browsable in the existing Grafana (Explore + one overview dashboard).
4. Do all of this without wearing out the monitoring Pi's eMMC or inventing a new
   storage tier — reuse the pool-backed Garage S3 that already exists on valen.

## What logs can and cannot tell us

- **Can:** surface application-internal failures invisible to metrics — DNS/upstream
  unreachable, panics/fatals/OOM, crash loops, unhandled exceptions, auth failures,
  and anything a service chooses to log. This is the layer that would have caught
  Jellyseerr.
- **Cannot:** guarantee a failure is logged at all (a service that hangs silently
  logs nothing), and cannot by itself distinguish a benign `ERROR` line from a real
  outage — which is why the initial alert set is **curated high-signal patterns**,
  not a generic error-rate firehose (see Alerts).

Logs and metrics are complementary: metrics say *something is wrong / a thing is
down*; logs say *why*. Neither replaces the other.

## Non-goals

- Not distributed tracing / request correlation.
- Not long-term or compliance-grade log archival — 30-day retention, matching
  Prometheus. Logs are operational, re-generated continuously, and not backed up
  (same stance as re-acquirable media library files).
- Not per-application bespoke dashboards — one overview dashboard plus Grafana
  Explore. Per-app dashboards are a follow-up if a need appears.
- Not replacing any metric or the blackbox probes.

## Architecture

Loki is the log-side twin of the metrics stack; the mapping fixes every placement
decision:

| Metrics (exists today) | Logs (this design)                          | Host                      |
|------------------------|---------------------------------------------|---------------------------|
| `node_exporter` (agent, all hosts) | **Alloy** (agent, all hosts)    | `all`                     |
| `prometheus` (store, loopback:9090) | **Loki** (store, loopback:3100)| `monitoring` (pi-cm5-1)   |
| Alertmanager           | **reused** (Loki ruler → same Alertmanager) | `monitoring`              |
| Grafana Prometheus datasource | **Grafana Loki datasource** (localhost:3100) | `monitoring`       |

### Loki (store)

- Role: `grafana.grafana.loki`, monolithic (single-binary) mode, bound to
  `127.0.0.1:3100`. Fronted by Traefik like Prometheus/Alertmanager/Grafana.
- **Storage backend: Garage S3.** A dedicated `loki` bucket + access key on the
  existing Garage instance on valen. Loki's TSDB index shipper and chunk store both
  target the bucket. Rationale over the alternatives (see Storage decision below).
- Only Loki's small WAL / query cache lives on the Pi's local disk. Bulk log data
  never touches the eMMC.
- **Retention: 30 days**, enforced by Loki's compactor with `retention_enabled`,
  matching `prometheus_storage_retention`. Deletes flow through to the S3 bucket.
- **Ruler:** enabled, evaluates the LogQL alert rules and pushes firing alerts to
  the existing Alertmanager (`http://localhost:9093`). Ruler rule storage is local
  (rules are config, provisioned by Ansible), alert delivery reuses Alertmanager.

### Alloy (agent)

- Role: `grafana.grafana.alloy`, on **`all`** hosts (mirrors `node_exporter`).
- Two collection sources:
  1. **Docker service discovery** — auto-discovers every running container, tails
     its logs, and labels each stream by container name / compose service. This is
     what makes the alerting fleet-wide with no per-service registry: a new service
     is picked up automatically the moment its container runs.
  2. **journald** — host-level logs (sshd/auth, systemd unit failures,
     unattended-upgrades, and the native Traefik/Prometheus/Grafana/Loki services
     that are not containers).
- Pushes to Loki over the network (see Push path).
- Alloy's WAL buffers through link outages, so **beelink** (offsite, flaky
  WireGuard) ships reliably and catches up after a drop.

### Push path

Alloy agents on other hosts must reach Loki's push endpoint. To stay consistent
with every other service (loopback bind + Traefik + wildcard cert + split-horizon
LAN IPv4), Loki is routed at **`loki.jardoole.xyz`** through Traefik.

- The push route carries a **Traefik basic-auth middleware** — agents are machines
  and cannot do the Authentik forward-auth SSO flow. Every Alloy carries a single
  shared vaulted basic-auth credential and pushes over TLS.
- Uniform agent config: **every** Alloy (including the one co-located on pi-cm5-1)
  pushes to `https://loki.jardoole.xyz/loki/api/v1/push`. Split-horizon DNS resolves
  it to the LAN IPv4 of pi-cm5-1; beelink reaches it over WireGuard. Both paths are
  TLS.
- **Dogfooding bonus:** because Loki is now a routed Traefik service, the Part 2
  coverage guard (`scripts/check-blackbox-coverage.py`) *forces* a
  `monitoring_blackbox_services` entry for it — Loki's own front door gets a
  liveness + cert probe for free. Registered `kind: app` (the push endpoint returns
  a non-2xx but valid HTTP status on a bare GET; confirm the code lands in
  `valid_status_codes` during implementation, else register `kind: edge`).

### Ordering within the monitoring layer

`playbooks/monitoring.yml` gains two imports, placed to mirror the metrics twins:

- **`alloy.yml`** right after `node-exporter.yml` (log agent ≈ metrics agent).
- **`loki.yml`** right before `prometheus.yml` (log store ≈ metrics store).

`loki.yml`'s first play provisions the Garage bucket/key (targets the `garage`
host), so storage exists before Loki starts — same pattern as `authentik.yml`.
Ordering is not strict beyond this: Alloy's WAL tolerates Loki not yet being up,
and the ruler retries Alertmanager, so cross-play startup races self-heal.

## Storage decision

Monitoring host `pi-cm5-1` has a 57 GB eMMC card with ~33 GB free. valen's pool is
11 TB (9.9 TB free) and already hosts Garage S3. Three options were weighed:

- **Local Pi eMMC** — rejected: 33 GB ceiling and eMMC write-wear under continuous
  log ingest; viable only for trivially short retention.
- **NFS mount of valen's pool** (the "how other apps do it" instinct — matches
  Nextcloud) — rejected: running Loki's index/chunk store over an NFS filesystem is
  discouraged upstream (POSIX locking / TSDB-shipper consistency). Higher fragility
  for no gain over S3.
- **Garage S3** (chosen) — Loki's officially-supported large-data backend,
  pool-backed via valen's existing object store, keeps bulk writes off the eMMC, and
  reuses the `garage-keys` provisioning convention already used by backups. The
  closest existing precedent for large valen-hosted service data is backups (Garage
  S3), not Nextcloud (NFS).

Expected volume: home-lab log rates, Loki's ~10× compression, 30-day retention →
single-digit GB on an 11 TB pool. The existing `HighDiskUsage` alert already watches
the pool.

## Alerts

Loki ruler evaluates LogQL over **all** container logs (`{job="docker"}`), never
pinned per-service — so a new service is covered automatically, with no registry and
no pre-commit guard (a deliberate contrast with the blackbox registry, which needs
one because each probe target is enumerated). Firing alerts route to the existing
Alertmanager → email. Starter set (curated, high-signal — grow over time):

- **`LogDNSResolutionFailure`** (critical) — matches
  `(?i)(EAI_AGAIN|ENOTFOUND|getaddrinfo|Temporary failure in name resolution)` in
  container logs over a short window. **This is the rule that catches the original
  Jellyseerr outage class.**
- **`LogPanicOrFatal`** (critical) — panic / fatal / segfault / `Out of memory` /
  OOM-kill patterns.
- **`LogCrashLooping`** (warning) — repeated container start/exit lines for the same
  container over a window (a container restarting in a loop).

Thresholds/`for:` windows tuned during implementation to avoid flapping. Exact
LogQL and label selectors finalized against real log samples on first deploy.

## Secrets

Four new vaulted values — two logical credentials. The basic-auth one needs two
representations because Traefik consumes a hash while Alloy needs the plaintext.
Claude cannot create these (vault files are off-limits); all are operator actions.
The **var names are fixed by this spec** so the playbooks and the vault entries
agree.

| Var name                     | Vault file                        | Consumed by                              | Generate with                              |
|------------------------------|-----------------------------------|------------------------------------------|--------------------------------------------|
| `vault_loki_s3_access_key`   | `group_vars/monitoring/vault.yml` | Loki storage config + Garage provisioning play | `scripts/garage-keygen.sh vault_loki_s3` (emits both keys) |
| `vault_loki_s3_secret_key`   | `group_vars/monitoring/vault.yml` | same                                     | ↑ same command                             |
| `vault_loki_push_password`   | `group_vars/all/vault.yml`        | Alloy on **every** host (push auth header) | operator-chosen strong password            |
| `vault_loki_push_htpasswd`   | `group_vars/monitoring/vault.yml` | Traefik basic-auth middleware on pi-cm5-1 | `htpasswd -nbB alloy '<that password>'` (or `openssl passwd -apr1` fallback) |

Non-secret companions in `main.yml` (not vault): the `loki` bucket name, the S3
endpoint/region, and `loki_push_username: alloy`. The S3 keys sit in `monitoring`
vault because the garage-keys convention keeps credentials with the consuming
service and Loki's inventory home is `[monitoring]`; `vault_loki_push_password` is
in `all` vault because Alloy runs on `all`. `vault_loki_push_password` and
`vault_loki_push_htpasswd` are the **same** username+password, plaintext vs. hashed
— generate the password once and derive both.

**Timing.** Locking the var names (above) is the only hard dependency for
implementation. Generating and vaulting can happen any time before the first deploy
and is best done up front: the Garage key must pre-exist (provisioning is unattended
and will not mint one — a missing vault var is an operator error the play does not
paper over), and doing it early avoids a deploy-time stall.

## Grafana

- New **Loki datasource** (`type: loki`, `url: http://localhost:3100`, `access:
  proxy`) added to `grafana_datasources` alongside the existing Prometheus
  datasource.
- One **logs overview dashboard** (grafana.com Loki dashboard, ID chosen at
  implementation) plus ad-hoc Grafana Explore over the Loki datasource for
  free-form log search. No per-app dashboards.

## Testing / validation

- `make precommit` (yamllint + ansible-lint + `--syntax-check` + blackbox-coverage)
  passes; the coverage guard confirms `loki` is registered.
- Static: confirm the Loki S3 config renders against the Garage endpoint vars and
  the ruler points at the local Alertmanager.
- Post-deploy (operator, out of band — playbooks are not run from here): Alloy on
  each host reaches Loki (basic-auth OK, TLS OK); container + journald streams appear
  in Grafana Explore; a deliberately-triggered DNS-failure log line fires
  `LogDNSResolutionFailure` end-to-end to email.

## Files

**New**

- `playbooks/loki.yml` — first play provisions the Garage `loki` bucket + key on the
  `garage` host (garage-keys convention); second play deploys `grafana.grafana.loki`
  on `monitoring` and drops the Traefik route.
- `playbooks/alloy.yml` — deploys `grafana.grafana.alloy` on `all`.
- `playbooks/templates/traefik-loki.yml.j2` — Traefik router for `loki.jardoole.xyz`
  + basic-auth middleware on the push route.
- `group_vars/alloy/main.yml` (+ `vault.yml`) *or* fold Alloy config into
  `group_vars/all/` — Alloy scrape config, Loki push URL, basic-auth cred reference.
  Decide during implementation which keeps the config with the concern most cleanly.

**Modified**

- `group_vars/monitoring/main.yml` — Loki role config (Garage S3 backend, 30-day
  retention, ruler → Alertmanager), the LogQL alert rules, the Loki Grafana
  datasource, the logs dashboard, and a **`loki` entry in
  `monitoring_blackbox_services`**.
- `group_vars/monitoring/vault.yml` — Loki S3 access/secret key + the Traefik
  basic-auth htpasswd hash. `group_vars/all/vault.yml` — the Alloy basic-auth
  plaintext password. All `vault_`-prefixed; see the Secrets section for the full
  list and who consumes each.
- `playbooks/monitoring.yml` — import `alloy.yml` (after node-exporter) and
  `loki.yml` (before prometheus).
- `CLAUDE.md` — monitoring-layer table row (Loki + Alloy + log alerts), the new
  `loki.jardoole.xyz` hostname, and the function-playbook list.

**Manual prerequisite (operator)**

- Split-horizon DNS record `loki.jardoole.xyz` → `pi-cm5-1` on the Ubiquiti router,
  same as every other service hostname. (Owner: operator, in progress.)

## Open follow-ups

- Expand the curated pattern set as new failure modes are observed.
- Optionally add a tuned generic error-rate alert once the curated set proves stable.
- Trace correlation / per-app log dashboards if a need appears.
- The IPv6→Cloudflare AAAA leak (inherited from Part 2) — Alloy pushes over the
  forced-IPv4 split-horizon path via the hostname; verify it does not prefer the
  AAAA record.
