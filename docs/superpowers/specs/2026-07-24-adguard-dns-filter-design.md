# AdGuard Home DNS filter — design

**Date:** 2026-07-24
**Status:** Approved (brainstorming) — ready for implementation plan
**Layer:** `applications` (deployed via `make app service=adguard`)
**Host:** `pi-cm5-3` (new `[adguard]` inventory group)

## Goal

Give the home network a filtering DNS resolver that the Ubiquiti router points at
as its **upstream**, so all external DNS resolution is filtered for:

- **Ads / trackers** (blocklists)
- **Porn / adult content** (AdGuard Parental Control category)
- **Social media** (AdGuard native "Blocked Services")

Additional requirements that shaped the design:

- **Config lives in code**, not in the Ubiquiti UI — versioned, reviewable,
  reproducible from git.
- **Disposable / easy recovery** — if the box dies from a home-lab failure, the
  home network returns to a working state with a single, documented operator step.
- The resolver is *only* the router's upstream for now — individual client devices
  are **not** repointed at it (no raw per-device DNS). That can widen later.

## Decision: AdGuard Home

Evaluated Pi-hole vs AdGuard Home vs Technitium against the requirements above.

| Requirement | Pi-hole | **AdGuard Home** | Technitium |
|---|---|---|---|
| Block ads/trackers | blocklists | blocklists | blocklists |
| Block porn | curate a blocklist | **one flag** (`parental_enabled`) | blocklist/app |
| Block social media | curate a blocklist | **native `blocked_services`** (named IDs) | blocklist |
| Config-as-code | v6 TOML + sqlite "gravity" DB (awkward to template) | **single `AdGuardHome.yaml`** (template it whole) | REST API only, no single declarative file |
| Footprint / simplicity | lightweight | single Go binary / one container | heaviest (.NET) |
| Encrypted upstream (DoH/DoT/DoQ) | needs external proxy | **native** | native |

**Chosen: AdGuard Home.** Two of the three block categories (porn, social media)
are first-class named toggles rather than third-party blocklists we must source and
trust, and its entire state is a single YAML file — a direct fit for the
"config in code" requirement and this repo's Ansible-templated conventions.
Technitium's strengths (authoritative zones, clustering, split-horizon) solve
problems the Ubiquiti already handles; it is overkill here.

## Architecture and data flow

```
LAN clients ──DNS──▶ Ubiquiti router ──(forward)──▶ AdGuard Home ──DoH──▶ Cloudflare/Quad9
                                                    (pi-cm5-3 :53, filters)
```

The router remains the LAN's DNS server. It forwards queries to AdGuard, which
applies filtering, resolves internal `*.jardoole.xyz` names from its own rewrite
table (see below), and forwards everything else upstream over **encrypted DoH**.

### Split-horizon ownership: service→host CNAMEs in AdGuard, host A-records in Ubiquiti

Today the Ubiquiti answers `*.jardoole.xyz` via per-service CNAME + A-record
overrides configured entirely in the UniFi UI. This design splits that table along
its natural seam:

- **The churny part — which service lives on which host — moves into AdGuard as
  CNAMEs** (in code). This is what changes when a service is relocated.
- **The stable part — which host has which LAN IP — stays in Ubiquiti** as a small
  set of per-host A-records. This is tied to hardware and rarely changes.

The result carries **zero LAN IPs in git**: the only IP anywhere in the AdGuard
config is the router's, referenced once.

```yaml
# AdGuardHome.yaml — service → host CNAMEs (no IPs)
filtering:
  rewrites:
    - {domain: 'jellyfin.jardoole.xyz',     answer: 'valen.jardoole.xyz'}
    - {domain: 'jellyseerr.jardoole.xyz',   answer: 'valen.jardoole.xyz'}
    - {domain: 's3.jardoole.xyz',           answer: 'valen.jardoole.xyz'}
    - {domain: 'radarr.jardoole.xyz',       answer: 'valen.jardoole.xyz'}
    - {domain: 'sonarr.jardoole.xyz',       answer: 'valen.jardoole.xyz'}
    - {domain: 'prowlarr.jardoole.xyz',     answer: 'valen.jardoole.xyz'}
    - {domain: 'qbittorrent.jardoole.xyz',  answer: 'valen.jardoole.xyz'}
    - {domain: 'grafana.jardoole.xyz',      answer: 'pi1.jardoole.xyz'}
    - {domain: 'auth.jardoole.xyz',         answer: 'pi1.jardoole.xyz'}
    - {domain: 'prometheus.jardoole.xyz',   answer: 'pi1.jardoole.xyz'}
    - {domain: 'alertmanager.jardoole.xyz', answer: 'pi1.jardoole.xyz'}
    - {domain: 'loki.jardoole.xyz',         answer: 'pi1.jardoole.xyz'}
    - {domain: 'nextcloud.jardoole.xyz',    answer: 'pi2.jardoole.xyz'}
    - {domain: 'vaultwarden.jardoole.xyz',  answer: 'pi2.jardoole.xyz'}
```

The service list above is the full set of routed home-LAN names, derived from the
authoritative `monitoring_blackbox_services` registry in `group_vars/monitoring`.
(`jellyfin-relay` is excluded — it is barn-local on beelink, not a home-LAN name.)

**Why a CNAME alone is not enough — the resolution-direction fix.** AdGuard sits
*above* the router (it is the router's upstream), and a CNAME rewrite is special:
AdGuard **resolves the CNAME target itself** and returns its IP. Left to its default
upstream (Cloudflare DoH), it would resolve `valen.jardoole.xyz` to valen's *public*
address — the LAN A-record lives in the router, which AdGuard cannot see. So AdGuard
must be told to resolve the **host names** via the router, using a domain-specific
upstream scoped to exactly those host FQDNs:

```yaml
upstream_dns:
  - https://dns.cloudflare.com/dns-query   # default: filtered external resolution
  # Host names resolve via the router, which holds their LAN A-records:
  - '[/valen.jardoole.xyz/pi1.jardoole.xyz/pi2.jardoole.xyz/]{{ adguard_router_ip }}'
```

**Scoping to the exact host FQDNs (not the whole `jardoole.xyz` suffix) is
deliberate — it prevents a resolution loop.** A nonexistent name like
`typo.jardoole.xyz` matches no rewrite and no host-upstream, so it falls to the
default upstream (Cloudflare) instead of bouncing router↔AdGuard indefinitely.

**AAAA leak fix (bonus, for free).** The repo's open follow-up — LAN IPv6 clients
falling through to Cloudflare because the router only overrides the A record — closes
automatically: every internal name now resolves via the router, which holds no AAAA
records, so IPv6-preferring clients receive NODATA and fall back to the LAN A-record.

**Host A-records (in Ubiquiti):** `valen.jardoole.xyz` and `pi1`–`pi4.jardoole.xyz`
(the Pis are labelled `piN`, not `pi-cm5-N`; beelink has no such record but carries
no home-LAN service names). This design uses `valen`, `pi1` (= inventory
`pi-cm5-1`, the monitoring/Authentik host) and `pi2` (= `pi-cm5-2`, Nextcloud/
Vaultwarden). **Confirm at implementation:** that the inventory→label mapping is
`pi-cm5-1 → pi1` and `pi-cm5-2 → pi2` (a swap would misroute those hosts' services),
and the router LAN IP (`adguard_router_ip`, assumed `192.168.1.1` — valen is
`192.168.1.197`, so the `/24` gateway is almost certainly `.1`).

**Consequence — internal names now depend on AdGuard's uptime.** This is the
accepted trade for config-in-code. It changes the manual Ubiquiti reconfiguration
(see Deployment) and reshapes recovery (see Recovery). It does **not** affect DNS
filtering availability — see the recovery section for why this coupling is bounded.

## Components

Follows the standard service pattern in this repo (dedicated group + `group_vars`,
role with **no `defaults/`**, one function playbook, `make app` deployable).

- **`[adguard]` inventory group** = `pi-cm5-3`. One-line host move later.
  pi-cm5-3 is the only `[servers]` Pi with no service groups assigned — always-on,
  on the home LAN, and covered by the `host-resilience` layer (watchdog +
  panic-on-hang auto-reboot), which matters because DNS is network-critical.
- **`group_vars/adguard/main.yml`** — image pin, DNS/UI ports, upstream DoH
  servers, blocklist URLs, `blocked_services` list, and the split-horizon rewrite
  table. All non-secret.
- **`group_vars/adguard/vault.yml`** — `vault_adguard_admin_password_hash` (bcrypt
  hash for AdGuard's own login; see UI section). `vault_`-prefixed, encrypted.
- **`roles/adguard`** — templates:
  - a Docker `compose.yml` (`restart: unless-stopped`), and
  - a **fully-rendered `AdGuardHome.yaml`** — the single source of truth.
- **`playbooks/adguard.yml`** — deploys the role; imported by the `applications`
  layer with one `import_playbook` line. Deployed via `make app service=adguard`.

### Config-as-code model

The templated `AdGuardHome.yaml` is authoritative. AdGuard rewrites this file when
settings change in its UI, so the operating rule is: **Ansible is authoritative;
the web UI is read-only / observability.** Each deploy overwrites any drift and
restarts the container.

**No backup job.** Because the entire config is regenerable from git, there is
nothing to snapshot — unlike every other service in this repo, AdGuard has no
`backups:` manifest. Its only runtime state (query log, stats) is ephemeral. This
is a deliberate, documented simplification.

## Filtering configuration

- **Ads / trackers** — AdGuard's default filter lists, declared as `filters:` in
  the YAML (URLs pinned in `group_vars`).
- **Porn** — `filtering: { parental_enabled: true }` (AdGuard's adult-content
  category — one flag).
- **Social media** — `blocked_services:` list of named service IDs (`facebook`,
  `instagram`, `tiktok`, `twitter`, `snapchat`, …). Applied globally; not
  schedule-gated (schedules are a possible later refinement).
- **Upstream** — encrypted **DoH** (e.g. `https://dns.cloudflare.com/dns-query`
  and/or Quad9), set in `upstream_dns`.

## Web UI: not exposed (SSH tunnel on demand)

In the config-as-code model the UI is **not a control surface** — it is only
observability (query log, stats, single-domain filtering test), needed
occasionally when tuning a false positive/negative.

**Decision: do not expose the UI.** It binds loopback inside the container. When
needed, reach it over an SSH port-forward — captured as a Makefile target so the
incantation isn't forgotten:

```make
adguard-ui: ## 🛡️  Open the AdGuard Home admin UI over an SSH tunnel (http://localhost:3000)
	@echo "AdGuard UI → http://localhost:3000  (Ctrl-C to close the tunnel)"
	ssh -L 3000:localhost:3000 pi-cm5-3
```

(Final local/remote port numbers match the role's configured UI port.)

This deliberately avoids: adding pi-cm5-3 to `[ingress]`, running a second Traefik
+ ACME cert, hand-registering an Authentik application, and adding a blackbox
registry entry — all of which a browser-exposed UI would require. It aligns with
both "simplest to get up and running" and the config-as-code choice. AdGuard's own
login (vaulted bcrypt password) is retained as basic protection even over the
tunnel. Promoting to always-on, Authentik-gated browser access later is a clean,
additive change.

**Aggregate observability without the UI:** the fleet already runs Alloy → Loki →
Grafana. AdGuard's query log can be tailed into Loki so "what's getting blocked"
is visible in Grafana alongside everything else. Treated as an optional follow-up,
not part of the core deliverable.

## Firewall (default-deny ufw; `firewall_rules_*` convention)

`group_vars/adguard/main.yml` declares `firewall_rules_adguard`:

- `53/tcp` **and** `53/udp`, `scope: docker`, **from the Ubiquiti gateway only**
  (least privilege — only the router forwards here). Widen the source to
  `homelab_subnet` only if devices are later pointed directly at AdGuard.
- **No** LAN-exposed UI port (UI is loopback + SSH tunnel).

Regenerate `docs/port-inventory.md` so the drift guard passes.

## Recovery model

DNS is the one service whose failure affects the whole network, so recovery is
first-class. Ordered from most to least preferred:

1. **Self-heal (common case).** pi-cm5-3 is always-on with the host-resilience
   watchdog, and the container runs `restart: unless-stopped`. A crashed
   container/host comes back on its own; internal names blink and return. Preferred
   action: let it heal / `docker compose restart`.
2. **Internet-now break-glass.** In the UniFi UI, revert the router's upstream to a
   public resolver (`1.1.1.1` / `9.9.9.9`). Internet resolution returns
   immediately. Internal `*.jardoole.xyz` names then resolve to their **public**
   Cloudflare records — hairpinning via Cloudflare for publicly-reachable services,
   or briefly unavailable for LAN-only ones — until AdGuard is back.
3. **Prolonged-outage break-glass.** The service→host CNAME table in
   `group_vars/adguard/main.yml` **doubles as the runbook**: re-add those
   (rarely-changing) per-service CNAME entries to the UniFi UI from the git file —
   the host A-records they point at were never removed, so this fully restores
   internal resolution. Git stays the single source of truth *and* the recovery
   reference — no steady-state duplication.

**Why the Authentik-style coupling is acceptable:** DNS filtering on port 53 has
**zero** dependency on any other service. Only *internal name resolution* couples
to AdGuard's uptime, and only the (unexposed) UI would couple to SSO if we ever
added it. This mirrors the repo's existing Prometheus/Alertmanager decision —
"delivery is loopback so it survives dependencies being down; only the UI needs
more." The blast radius is bounded and recoverable by the steps above.

## Deployment (manual Ubiquiti steps — the one part outside code)

After `make app service=adguard` succeeds and DNS answers on `pi-cm5-3:53`:

1. **Point the router's upstream DNS at `pi-cm5-3`'s LAN IP.**
2. **Remove the per-service overrides from the UniFi UI, keeping the per-host
   A-records** (`valen`, `pi1`, `pi2`, …). The service names then forward upstream
   to AdGuard, whose CNAMEs answer them and chase the target back to the host
   A-records the router still holds. The service→host mapping is preserved in
   `group_vars/adguard/main.yml`.

Both steps are documented here and in the role/playbook headers per the repo's
"document what/why/what-it-resolves" rule.

## Out of scope (YAGNI)

- **Backups** — config is code; nothing to snapshot.
- **HA / second instance** — recovery is manual revert, per decision.
- **Traefik / Authentik / ingress for the UI** — UI is unexposed (SSH tunnel).
- **Blackbox monitoring entry** — only required for Traefik-routed services; AdGuard
  is not routed. A blackbox DNS-probe for liveness is a possible later follow-up.
- **Per-device (raw) DNS** — router-upstream only for now.
- **Loki query-log integration** — optional follow-up, not core.

## Implementation checklist (for the plan)

- [ ] `[adguard]` group in `hosts.ini` = `pi-cm5-3`.
- [ ] `group_vars/adguard/main.yml` (image pin, ports, upstream DoH + the
      host-scoped `[/valen…/pi1…/pi2…/]` router upstream, `adguard_router_ip`,
      blocklists, `blocked_services`, the 14 service→host CNAME rewrites,
      `firewall_rules_adguard`).
- [ ] `group_vars/adguard/vault.yml` (`vault_adguard_admin_password_hash`).
- [ ] `roles/adguard` — compose + fully-rendered `AdGuardHome.yaml` (no `defaults/`).
- [ ] `playbooks/adguard.yml` + one `import_playbook` line in the applications layer.
- [ ] `make adguard-ui` target.
- [ ] Regenerate `docs/port-inventory.md`.
- [ ] `make precommit` clean.
- [ ] Confirm `pi-cm5-1 → pi1` / `pi-cm5-2 → pi2` label mapping + router LAN IP.
- [ ] Manual: repoint Ubiquiti upstream + remove per-service overrides (keep host
      A-records).
