# Prometheus & Alertmanager UIs behind Authentik forward-auth

**Date:** 2026-07-23
**Status:** Approved, ready to implement

## Problem

The Prometheus (`prometheus.jardoole.xyz`) and Alertmanager
(`alertmanager.jardoole.xyz`) web UIs are reachable by anyone on the LAN with no
authentication. They expose the full metric store, alert state, and silence
controls. They should sit behind Authentik SSO like the rest of the platform.

## Why forward-auth (not native OIDC)

Neither Prometheus nor Alertmanager has any native login or OIDC support — they
serve their UI unauthenticated by design and delegate access control to a
fronting proxy. So this uses the **same mechanism as the *arr stack**: a Traefik
`forwardAuth` middleware that defers each request to Authentik's embedded
outpost. It is *not* the native-OIDC path used by Grafana/Jellyseerr (those apps
speak OIDC themselves; these cannot).

## Key simplification: everything is co-located on pi-cm5-1

Prometheus, Alertmanager, Authentik, the Authentik embedded outpost, and the
fronting Traefik **all run on pi-cm5-1** (it is in `[monitoring]`, `[authentik]`,
and `[ingress]`). Unlike the media stack — where valen forwards across hosts to
pi-cm5-1's outpost and hits the `X-Forwarded-Host` scrubbing problem documented
in `docs/media-stack-migration.md` — here the Traefik doing the forward-auth
check and the outpost answering it are the same host. No cross-host trust issue.

## What does NOT change (important)

All internal traffic is loopback and never traverses Traefik or Authentik:

- Grafana → Prometheus over `http://localhost:9090` (`grafana_datasources`).
- Prometheus → Alertmanager over `localhost:9093` (`prometheus_alertmanager_config`).
- Prometheus self-scrape + Alertmanager scrape over `localhost` (`prometheus_scrape_configs`).

Consequences:

- **Alert delivery keeps working even if Authentik is down.** Only the *UIs* are
  gated. A firing alert still routes Prometheus → Alertmanager → email
  regardless of Authentik/Traefik state; the operator just cannot open the web
  UI to view or silence until Authentik recovers. Acceptable.
- **No `/api` bypass policy needed.** Unlike Prowlarr/Radarr (whose apps call
  each other's `/api` through the public URL), nothing calls the
  Prometheus/Alertmanager HTTP API through the public hostname — so the auth gate
  can be total, with no exception policy.

## Changes

### 1. Ansible / Traefik (automated)

**a. Deploy the forward-auth middleware to pi-cm5-1's Traefik.**
The existing `playbooks/templates/traefik-forward-auth.yml.j2` is already
host-agnostic (targets `https://auth.{{ traefik_domain }}/outpost.goauthentik.io/auth/traefik`),
so it is reused verbatim. Add a task to **`playbooks/prometheus.yml`** — the play
that already deploys the Prometheus and Alertmanager Traefik routers — that
templates it to `/etc/traefik/conf.d/forward-auth.yml` (owner/group `traefik`,
mode `0640`), mirroring `playbooks/media-forward-auth.yml`. No new function
playbook: it is one templated file for the routers this play already owns.

**b. Gate the two routers.**
Add the middleware reference to both router templates:

```yaml
    prometheus:      # (and alertmanager:)
      rule: "Host(`prometheus.{{ traefik_domain }}`)"
      service: prometheus
      middlewares:
        - authentik-forward-auth@file
      tls:
        certResolver: letsencrypt
```

Files: `playbooks/templates/traefik-prometheus.yml.j2`,
`playbooks/templates/traefik-alertmanager.yml.j2`.

**c. Flip blackbox `kind: app` → `kind: edge`.**
In `group_vars/monitoring/main.yml`, `monitoring_blackbox_services`, change the
`prometheus` and `alertmanager` entries from `kind: app` to `kind: edge`, with a
comment explaining why: behind forward-auth an unauthenticated probe gets a `302`
redirect to Authentik (in `valid_status_codes`), so `probe_success` only proves
Traefik+Authentik are up — a false-green for the service itself. `edge` keeps
them probed for TLS-expiry/cert coverage but excludes them from the
`BlackboxProbeFailed` liveness alert.

**No liveness is lost:** the `prometheus` and `alertmanager` scrape jobs already
scrape `localhost:9090` / `localhost:9093`, so `up{job="prometheus"}` and
`up{job="alertmanager"}` cover liveness via the existing `InstanceDown` alert.
The blackbox-coverage pre-commit guard still passes — both services remain in the
registry, only their `kind` changes.

### 2. Authentik (manual UI — documented, not automated)

Per the `authentik-app` skill and `docs/media-stack-migration.md` forward-auth
recipe, for **each** of `prometheus` and `alertmanager`:

1. **Providers → Create → Proxy Provider**
   - Name: `<service>-forward-auth` (e.g. `prometheus-forward-auth`)
   - Authorization flow: `default-provider-authorization-implicit-consent`
   - Forward auth mode: **Forward auth (domain level)**
   - External host: `https://<service>.jardoole.xyz`
   - Signing key: **authentik Self-signed Certificate** (without it the outpost
     endpoints 404)
2. **Applications → Create**
   - Name / Slug: `<service>`
   - Provider: the one from step 1
   - **Bind an access policy to the `Grafana Admins` group** (deny-by-default):
     the observability-stack admins. No new group is created — this reuses the
     group Grafana already maps to the `Admin` role
     (`grafana_ini.auth.generic_oauth.role_attribute_path`).
3. **Outposts → embedded outpost → edit → add both providers**, so the outpost
   on pi-cm5-1 serves them.
4. **No Expression Policy / `/api` bypass** (see "What does NOT change").

### 3. Docs

- Update `CLAUDE.md`: note in the monitoring-layer row that Prometheus and
  Alertmanager are now SSO-gated (forward-auth) and therefore edge-probed for
  cert coverage rather than liveness.
- Add a short "Prometheus/Alertmanager SSO" note where the monitoring layer's
  auth story lives, pointing at this spec and the reused forward-auth middleware.

## Access model summary

| UI | Auth | Allowed group |
|---|---|---|
| Grafana | native OIDC | `Grafana Admins` → Admin, `Grafana Editors` → Editor, else Viewer |
| Prometheus | forward-auth | `Grafana Admins` |
| Alertmanager | forward-auth | `Grafana Admins` |

## Out of scope

- No change to Grafana's existing native-OIDC integration.
- No change to Authentik's loopback binding (the outpost is reached via the
  public auth URL → pi-cm5-1 Traefik → loopback, unchanged).
- The AAAA/IPv6 split-horizon leak (separate open follow-up) is untouched; the
  blackbox probes already force IPv4.
