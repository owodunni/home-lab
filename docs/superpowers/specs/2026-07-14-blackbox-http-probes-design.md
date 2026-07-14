# Blackbox HTTP health probes for user-facing apps — design

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

This gap is real: the Jellyseerr DNS-race incident is *not* the case this catches
(that was an outbound failure with the front door still serving — see the
Non-goals), but the same class of "process alive, service not actually serving"
failures currently pages no one.

## Goal

Add HTTP front-door probing for the human-facing web UIs so Alertmanager emails
when any of them stops responding correctly, or when its origin TLS certificate is
close to expiry.

## Non-goals

- **Not** a fix for outbound/dependency failures like the Jellyseerr `EAI_AGAIN`
  DNS-race — the app's inbound front door stayed up throughout that incident, so an
  HTTP probe would have passed. That class is Part 3 (Loki log-based alerting),
  designed separately.
- **Not** probing internal-only tools (the *arr apps behind forward-auth). Scope is
  user-facing UIs only.
- **Not** fixing the IPv6→Cloudflare AAAA leak (see Findings) — recorded as a
  follow-up.

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
scrapes it via the standard multi-target relabel pattern: the scrape job iterates a
target list, passes each URL to blackbox as `__param_target`, and blackbox performs
the probe and returns `probe_*` metrics. Alert rules on those metrics route to email
through the existing Alertmanager config. A Grafana dashboard visualizes probe
status and cert expiry.

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

Rationale for `valid_status_codes`: all six apps answer their root path with a 2xx
or a login 3xx; 401/403 are accepted so the module stays correct if a forward-auth
app is ever probed.

### Targets & scrape job

`monitoring_blackbox_targets` in `group_vars/monitoring/main.yml`:

```yaml
monitoring_blackbox_targets:
  - "https://jellyseerr.jardoole.xyz"
  - "https://jellyfin.jardoole.xyz"
  - "https://nextcloud.jardoole.xyz"
  - "https://vaultwarden.jardoole.xyz"
  - "https://grafana.jardoole.xyz"
  - "https://auth.jardoole.xyz"
```

Scrape job appended to `prometheus_scrape_configs` (standard blackbox multi-target
relabeling):

```yaml
- job_name: "blackbox"
  metrics_path: /probe
  params:
    module: [http_app_2xx]
  static_configs:
    - targets: "{{ monitoring_blackbox_targets }}"
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: "127.0.0.1:9115"
```

`instance` becomes the probed URL, so alerts name the affected app directly.

### Alerts

Appended to `prometheus_alert_rules` in `group_vars/monitoring/main.yml`:

- **`BlackboxProbeFailed`** — `probe_success == 0`, `for: 5m`, severity
  **critical**. A user-facing app's front door has been unreachable or returning an
  unaccepted status for 5 minutes.
- **`BlackboxCertExpiringSoon`** — `probe_ssl_earliest_cert_expiry - time() <
  14 * 24 * 3600`, `for: 1h`, severity **warning**. Origin TLS cert within 14 days
  of expiry — a safety net for a stalled Traefik ACME renewal (which normally
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
Verification steps for the operator after applying:

1. `blackbox_exporter` active on pi-cm5-1, listening on `127.0.0.1:9115`.
2. Prometheus `blackbox` job shows all six targets `UP` with `probe_success == 1`.
3. Manual negative test: probe a deliberately-wrong path or stop one app briefly →
   `probe_success` goes to 0 and `BlackboxProbeFailed` enters pending/firing.
4. `probe_ssl_earliest_cert_expiry` reports a sane future timestamp per target.
5. Grafana dashboard 7587 renders all six targets.
6. `make precommit` passes (yamllint / ansible-lint).

## Files touched

- `playbooks/blackbox-exporter.yml` (new)
- `playbooks/monitoring.yml` (add import, before prometheus.yml)
- `group_vars/monitoring/main.yml` (targets, module config, scrape job, 2 alerts,
  dashboard 7587)
- `CLAUDE.md` (monitoring layer entry + DNS model note)

## Open follow-ups (not in this work)

- IPv6→Cloudflare AAAA leak on the LAN.
- Part 3: Loki log-based alerting (catches the outbound/dependency failure class
  this probe does not).
