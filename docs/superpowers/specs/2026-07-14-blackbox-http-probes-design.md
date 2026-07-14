# Blackbox HTTP health probes for routed services — design

**Date:** 2026-07-14
**Status:** Approved (pending spec review)
**Layer:** monitoring

## Problem

Existing monitoring watches three failure surfaces: host/process reachability
(`node_exporter` → `InstanceDown` on `up == 0`), per-container resource faults
(`cadvisor` → `ContainerOOMKilled`, `ContainerFrequentRestart`), and drive/backup
health. None of them detect **"the container is Up but the application's HTTP
front door is broken"** — a 5xx from the app, a crashed web frontend that keeps
the process alive, a mis-routed Traefik rule, or a silently expired TLS cert.

There is also a **process gap**: adding a new routed service touches only its own
Traefik template (`playbooks/templates/traefik-<svc>.yml.j2`) — nothing forces the
operator to also add monitoring, so a new service is silently unprobed.

## Goal

Add HTTP front-door probing for every routed service that a probe can meaningfully
test, so Alertmanager emails when one stops responding correctly or its origin TLS
cert nears expiry — and make it **structurally impossible to forget** a new service
by enforcing registry coverage in pre-commit.

## What a probe can and cannot test (scope rationale)

**Every routed service is probed.** A single probe yields two independent signals,
and which are trustworthy depends on the auth model — not on any internal-vs-
external distinction (meaningless in a home lab):

- **`probe_ssl_earliest_cert_expiry` (cert) — trustworthy for all.** The TLS
  handshake completes before any HTTP response, so cert expiry is valid for every
  routed service regardless of auth.
- **`probe_success` (liveness) — trustworthy only without forward-auth.** For an
  own-auth / no-auth service the app (or its own login page) answers, so
  `probe_success` reflects the app actually serving. But Traefik's forward-auth
  middleware runs *before* it proxies to the backend: an unauthenticated probe of a
  forward-auth app gets Authentik's redirect *without Traefik ever contacting the
  app*, so `probe_success` stays green even if the app is dead — a false signal.

The registry therefore tags each service `kind: app` or `kind: edge`:

- **`app`** (own/no auth): jellyseerr, jellyfin, nextcloud, vaultwarden, grafana,
  authentik, prometheus, alertmanager, garage. Both signals used.
- **`edge`** (forward-auth): prowlarr, qbittorrent, radarr, sonarr. Probed for cert
  coverage; **excluded from the liveness alert** via a `probe_kind` label.

A liveness-meaningful probe for the `edge` apps (a forward-auth-exempt health path,
or a probe from the app host against the loopback port) is a separate future piece
of work. (All subdomains currently share one wildcard cert, so `edge` cert probes
are redundant today, but they make the check uniform and catch a future per-route
cert drifting onto a bad/expired cert.)

## Non-goals

- **Not** a fix for outbound/dependency failures like the Jellyseerr `EAI_AGAIN`
  DNS-race — the app's inbound front door stayed up throughout that incident, so an
  HTTP probe would have passed. That class is Part 3 (Loki log-based alerting),
  designed separately.
- **Not** trusting forward-auth apps' liveness — they are probed (for TLS/cert
  coverage) but excluded from the liveness alert, since an unauthenticated probe
  cannot see past Authentik. A liveness-meaningful probe for them is a separate
  future piece of work.
- **Not** fixing the IPv6→Cloudflare AAAA leak (see Findings) — recorded as a
  follow-up.
- **Not** refactoring Traefik routing into a shared source-of-truth registry (the
  robust-but-heavy option) — the pre-commit guard closes the "don't forget" gap
  without touching the working per-template routing model.

## Key finding: DNS resolution model

From pi-cm5-1, the app hostnames resolve differently by address family:

- **IPv4 (A):** `jellyseerr.jardoole.xyz` → CNAME `valen.jardoole.xyz` →
  `192.168.1.197` (the LAN host). This is the Ubiquiti router's split-horizon
  override — internal clients reach the app directly on the LAN.
- **IPv6 (AAAA):** → Cloudflare edge (`2a06:98c1::` ∈ Cloudflare's `2a06:98c0::/29`).
  The router overrides the A record but **not** the AAAA, so any IPv6-preferring
  client on the LAN reaches the apps via Cloudflare instead of the LAN.

**Design consequence:** the probe module forces `preferred_ip_protocol: ip4`
(no fallback) so blackbox follows the IPv4 CNAME to the LAN and hits each app's own
Traefik directly — never Cloudflare. This makes the probe an *origin-direct* test
of the infrastructure we control (Traefik routing + app + real origin cert) and
avoids false positives from Cloudflare WAF/bot-challenges or IPv6 egress.

**Follow-up (out of scope):** the IPv6 AAAA leak is a latent quirk worth fixing
separately (add a split-horizon AAAA override on the Ubiquiti resolver, or remove
the public AAAA / stop proxying valen).

## Architecture

`prometheus.prometheus.blackbox_exporter` role deploys a blackbox_exporter systemd
service on pi-cm5-1 (`[monitoring]`), bound to loopback. Prometheus (same host)
scrapes it via the standard multi-target relabel pattern: the scrape job iterates
the derived target list, passes each URL to blackbox as `__param_target`, and
blackbox performs the probe and returns `probe_*` metrics. Alert rules on those
metrics route to email through the existing Alertmanager config. A Grafana
dashboard visualizes probe status and cert expiry. A pre-commit guard enforces that
every routed service appears in the registry.

This mirrors every existing exporter (node, smartctl, cadvisor, intel_gpu): a flat
function playbook → collection role → config in `group_vars/monitoring/` → one
import line in the monitoring layer.

### Component & placement

- **Service:** `blackbox_exporter` (systemd, via the collection role).
- **Host:** pi-cm5-1 (`[monitoring]`).
- **Bind:** `127.0.0.1:9115` — loopback only, same as Prometheus/Alertmanager/
  Grafana; Prometheus scrapes it over localhost, no external exposure.
- **Playbook:** new `playbooks/blackbox-exporter.yml`, `hosts: monitoring`,
  `become: true`, `roles: [prometheus.prometheus.blackbox_exporter]`.
- **Layer wiring:** imported in `playbooks/monitoring.yml` among the exporters,
  **before** `prometheus.yml` (Prometheus must find the target up when it scrapes).

### Probe module

Custom module `http_app_2xx` defined in `blackbox_exporter_configuration_modules`
(in `group_vars/monitoring/main.yml`, per the no-role-defaults rule):

```yaml
http_app_2xx:
  prober: http
  timeout: 5s
  http:
    preferred_ip_protocol: ip4      # follow the IPv4 CNAME to the LAN, not the
    ip_protocol_fallback: false     # IPv6/Cloudflare AAAA — origin-direct probe
    follow_redirects: false         # test the front door's own response, don't
                                    # chase login redirects into auth flows
    valid_status_codes: [200, 204, 301, 302, 307, 308, 401, 403]
    tls_config: {}                  # verify the real origin cert; SNI = hostname
```

Rationale for `valid_status_codes`: the probed apps answer their root path with a
2xx or a login 3xx; 401/403 are accepted for the basic-auth/IP-allowlist-fronted
UIs (prometheus, alertmanager) and garage's S3 `403 AccessDenied`.

### Service registry (single place a service is declared for monitoring)

`monitoring_blackbox_services` in `group_vars/monitoring/main.yml` — a map keyed by
the Traefik template's service name (`traefik-<name>.yml.j2`). Every routed service
MUST appear here (enforced by the guard below). Each entry carries a `kind`
(`app` = liveness-meaningful; `edge` = forward-auth, cert-only) and an optional
`hostname:` overriding the default `<name>.{{ traefik_domain }}` where the route
name differs from the subdomain. (A `probe: false` escape hatch stays available for
a genuinely non-probeable route — none today.)

```yaml
monitoring_blackbox_services:
  jellyseerr:   { kind: app }
  jellyfin:     { kind: app }
  nextcloud:    { kind: app }
  vaultwarden:  { kind: app }
  grafana:      { kind: app }
  authentik:    { kind: app, hostname: "auth.{{ traefik_domain }}" }
  prometheus:   { kind: app }
  alertmanager: { kind: app }
  garage:       { kind: app, hostname: "s3.{{ traefik_domain }}" }
  # Forward-auth apps: probed for cert coverage, but an unauthenticated probe only
  # reaches Authentik, so probe_success is a false-green for liveness — kind: edge
  # excludes them from the liveness alert (see the probe_kind label below).
  radarr:       { kind: edge }
  sonarr:       { kind: edge }
  prowlarr:     { kind: edge }
  qbittorrent:  { kind: edge }
```

`monitoring_blackbox_targets` is **derived** from the registry (all probed entries,
grouped by `kind`, → `https://<hostname>`) rather than hand-maintained, so the
registry is the one place to edit.

### Scrape job

Appended to `prometheus_scrape_configs`. Two `static_configs` blocks attach a
`probe_kind` label per group so alerts can scope on it; standard blackbox
multi-target relabeling otherwise:

```yaml
- job_name: "blackbox"
  metrics_path: /probe
  params:
    module: [http_app_2xx]
  static_configs:
    - targets: "{{ monitoring_blackbox_targets.app }}"
      labels: { probe_kind: app }
    - targets: "{{ monitoring_blackbox_targets.edge }}"
      labels: { probe_kind: edge }
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: "127.0.0.1:9115"
```

`instance` becomes the probed URL, so alerts name the affected app directly, and
`probe_kind` distinguishes liveness-meaningful (`app`) from cert-only (`edge`).

### Enforcement: pre-commit coverage guard

A small check script (`scripts/check-blackbox-coverage.py`, run as a local
pre-commit hook and therefore by `make precommit`) makes forgetting a service a
build failure:

1. **Routed set** = basenames of `playbooks/templates/traefik-*.yml.j2`, minus the
   infrastructure templates that are not services (`wildcard-tls`, `forward-auth`,
   `static`).
2. **Registry set** = keys of `monitoring_blackbox_services`
   (`yaml.safe_load` of `group_vars/monitoring/main.yml`).
3. **Fail** if `routed − registry` is non-empty ("routed service X has no monitoring
   registry entry — add `kind: app`, `kind: edge`, or `probe: false` with a
   reason"). Also fail on `registry − routed` (a registry entry for a service that
   is no longer routed), to keep the registry honest.

The hook triggers on changes to `playbooks/templates/` or
`group_vars/monitoring/main.yml`. Adding a new routed service then fails the commit
until its one registry line is added — turning "don't forget" into an enforced gate
where the operator actually works.

### Alerts

Appended to `prometheus_alert_rules` in `group_vars/monitoring/main.yml`:

- **`BlackboxProbeFailed`** — `probe_success{probe_kind="app"} == 0`, `for: 5m`,
  severity **critical**. Scoped to `probe_kind="app"` so forward-auth (`edge`)
  targets — whose `probe_success` is a false-green — are excluded. An app's front
  door has been unreachable or returning an unaccepted status for 5 minutes.
- **`BlackboxCertExpiringSoon`** — `probe_ssl_earliest_cert_expiry - time() <
  14 * 24 * 3600`, `for: 1h`, severity **warning**. Unscoped — applies to **all**
  probed targets (`app` and `edge`), since cert expiry is a valid signal
  everywhere. A safety net for a stalled Traefik ACME renewal (which normally
  renews at ~30 days remaining). Watches the real origin cert because the probe is
  forced to IPv4.

### Dashboard & docs

- Grafana dashboard **7587** ("Prometheus Blackbox Exporter") added to
  `grafana_dashboards`, wired to the Prometheus datasource.
- **CLAUDE.md:** add `blackbox-exporter.yml` to the monitoring layer's
  function-playbook list, and add a short note documenting the Ubiquiti
  split-horizon DNS model (`*.jardoole.xyz` → CNAME `<host>.jardoole.xyz` → LAN IP
  over IPv4) that the probe design relies on.

## Testing / verification

Per repo constraints, playbook runs are the operator's (not automated here).

Automated (CI/pre-commit):
- `check-blackbox-coverage.py` passes on the current tree and fails when a
  `traefik-<new>.yml.j2` is added without a registry entry (verify with a scratch
  template during implementation).
- `make precommit` (yamllint / ansible-lint / the new hook) passes.

Operator, after applying the playbook:
1. `blackbox_exporter` active on pi-cm5-1, listening on `127.0.0.1:9115`.
2. Prometheus `blackbox` job shows every probed target `UP` with
   `probe_success == 1`.
3. Manual negative test: probe a deliberately-wrong path or stop one app briefly →
   `probe_success` goes to 0 and `BlackboxProbeFailed` enters pending/firing.
4. `probe_ssl_earliest_cert_expiry` reports a sane future timestamp per target.
5. Grafana dashboard 7587 renders all probed targets.

## Files touched

- `playbooks/blackbox-exporter.yml` (new)
- `playbooks/monitoring.yml` (add import, before prometheus.yml)
- `group_vars/monitoring/main.yml` (registry, derived targets, module config,
  scrape job, 2 alerts, dashboard 7587)
- `scripts/check-blackbox-coverage.py` (new coverage guard)
- `.pre-commit-config.yaml` (register the guard hook)
- `CLAUDE.md` (monitoring layer entry + DNS model note)

## Open follow-ups (not in this work)

- IPv6→Cloudflare AAAA leak on the LAN.
- A forward-auth-exempt health probe so radarr/sonarr/prowlarr/qbittorrent get a
  trustworthy liveness signal (retag their registry entries `kind: app`).
- Part 3: Loki log-based alerting (catches the outbound/dependency failure class
  this probe does not).
