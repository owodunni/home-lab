# Host Firewalls — Design Spec

**Date:** 2026-07-19
**Status:** Approved design, not yet implemented
**Author:** Alexander Poole (with Claude)

## Goal

Add a host firewall to every node in the lab as the next function playbook in
the `security` layer (ahead of future SSH hardening). Default-deny inbound on
every host, with per-service allowlists and source restrictions — full
defense-in-depth, not just a perimeter backup.

## Why host firewalls when the router already has zones

The UniFi Zone-Based Firewall (see
`2026-07-15-network-zone-segmentation-design.md`) gates who gets *into* the
homelab, but:

- **Intra-zone traffic is unfiltered.** A compromised homelab host can reach
  every port on every other homelab host. Host firewalls are the only control
  that limits lateral movement inside the Internal zone.
- **beelink has no zone protection at all.** It sits on an untrusted barn LAN
  (`192.168.1.0/24`, colliding with the home LAN's subnet) reachable only via
  WireGuard. A host firewall is its primary network defense.
- The host layer survives a router misconfiguration.

## Decisions (with rationale)

| Decision | Choice | Why |
|---|---|---|
| Threat model | Full defense-in-depth: per-host allowlists, source-restricted | Lateral movement is the threat the router zones cannot touch |
| Direction | Inbound only; outbound unrestricted | Blocking unexpected listeners is 90% of the value; egress filtering means cataloguing every external endpoint and breaks silently — deferred |
| Docker-published ports | Firewall both paths: ufw INPUT for native listeners **and** DOCKER-USER rules for container-published ports | Docker routes published ports through its own FORWARD chains, bypassing ufw INPUT — a ufw deny silently does not protect them |
| Enforcement | ufw via `community.general.ufw`; DOCKER-USER block templated into ufw's `after.rules` (ufw-docker pattern) | Boring, inspectable (`ufw status`), idempotent module. Pure nftables was cleaner but has Docker-coexistence footguns and no module; firewalld is unidiomatic on Debian and still needs DOCKER-USER handling |
| Play target | `hosts: all`, **no** `[firewall]` group | Fail-closed coverage: a new host cannot be forgotten. Matches `unattended-upgrades.yml` / `node-exporter.yml` precedent — a firewall is a host property, not a service that moves. Temporary exclusion is `--limit` or `ufw disable`, not an inventory edit |
| Rule data location | Baseline in `group_vars/all`, per-service rules in `group_vars/<service>/main.yml`, host one-offs in `host_vars/` | Rules travel with the service (one-line migration stays true); host oddities (beelink barn) stay per-host |
| Lockout safety | Auto-rollback systemd timer on every host, cancelled by Ansible reconnecting through the new rules | beelink is a 1.5 h drive away; the confirmation step is Ansible's own ability to get back in — no manual ceremony |
| Port documentation | `docs/port-inventory.md` **generated** from group_vars by a script, drift-guarded by pre-commit | A hand-maintained doc would be a second source of truth; generation makes it always trustworthy (same pattern as `check-blackbox-coverage.py`) |

## Rule data model

A rule entry:

```yaml
- name: nfs                    # short slug, used in comments/doc
  port: 2049                   # int or "start:end" range
  proto: tcp                   # tcp | udp
  from: [nfs_clients]          # list of source aliases and/or literal CIDRs
  scope: host                  # host (ufw INPUT) | docker (DOCKER-USER)
  comment: NFS export of the MergerFS pool to the Docker fleet
```

Placement:

- **`group_vars/all/main.yml`** —
  - `firewall_source_aliases`: named sources so rules read semantically —
    `home_lan: 192.168.1.0/24`, `wg_subnet`, `monitoring_hosts`,
    `nfs_clients`, `barn_lan`, … Alias resolution happens in the role; a
    rule's `from` may mix aliases and literal CIDRs.
  - `firewall_rules_base`: SSH (22/tcp) from `home_lan` and `wg_subnet`
    (beelink additionally allows `barn_lan` via `host_vars` — see below).
  - `firewall_rollback_minutes` (default 10) and ufw policy settings
    (deny incoming, allow outgoing, logging low).
- **`group_vars/<service>/main.yml`** — `firewall_rules_<service>` for every
  service with an off-host listener (e.g. `firewall_rules_nfs_server`,
  `firewall_rules_ingress` for 80/443). Services that bind loopback behind a
  co-located Traefik (the majority) declare nothing.
- **`host_vars/beelink.yml`** — barn one-offs: WireGuard UDP port, SSH from
  the barn LAN (local recovery when the tunnel is down), the Jellyfin-relay
  ports the barn TVs use.

**Merge mechanic:** group_vars lists at different precedence levels *replace*
rather than merge, and valen is in ten groups. So each scope defines its own
variable name matching `firewall_rules_*`; the role collects them with
`lookup('varnames', '^firewall_rules_')` and flattens. No two scopes may
define the same variable name.

**Ports are never secrets:** all rule variables live in `main.yml`, never
`vault.yml`, so the doc generator can read them.

## The `firewall` role

Generic infrastructure role, no `defaults/` (repo convention — all values from
group_vars). Tasks:

1. Install ufw; install the `firewall-rollback.service` + `.timer` units.
2. Arm the rollback timer (one-shot: runs `ufw disable` after
   `firewall_rollback_minutes`).
3. Set defaults: deny incoming, allow outgoing, logging low.
4. Apply every collected `scope: host` rule via `community.general.ufw`
   (idempotent). Reconciliation is detect-and-fail: after applying, the role
   diffs `ufw show added` against the desired set and fails loudly on any
   unmanaged allow rule, telling the operator how to remove it — it never
   auto-resets, since a stray rule might be deliberate.
5. Template the `scope: docker` rules into the DOCKER-USER section of
   `/etc/ufw/after.rules`: allow established/related, allow intra-Docker
   traffic, allow declared sources to declared container ports, drop other
   off-host traffic to published ports. Reload ufw on change.
6. Enable ufw.
7. `meta: reset_connection`, then a trivial task (the reconnect proof).
8. Stop and disable the rollback timer.

If step 7's reconnect fails, step 8 never runs, the timer fires, ufw disables
itself, and the host heals. The next playbook run retries cleanly.

`playbooks/firewall.yml` (`hosts: all`, `become: true`) applies the role and is
imported at the **top** of `playbooks/security.yml`, before
`unattended-upgrades.yml` (and before the future SSH-hardening playbook).

## Known Docker-published ports (as of design time)

The loopback-binding convention holds for nearly everything (each app publishes
`127.0.0.1:<port>` behind a co-located Traefik). Known exceptions that need
`scope: docker` rules, both scraped only by pi-cm5-1:

- `cadvisor` — publishes `{{ cadvisor_port }}:8080` on 0.0.0.0.
- `intel_gpu_exporter` — publishes its port on 0.0.0.0 (valen).

The implementation port sweep must confirm this list and catch any others
(e.g. relay paths on beelink serving barn TVs).

## Port inventory document

`scripts/render-port-inventory.py` parses `hosts.ini` +
`group_vars`/`host_vars` `main.yml` files, resolves group membership per host,
and renders `docs/port-inventory.md`: a per-host table of port, protocol,
scope, allowed sources, purpose (the rule's `comment`). A pre-commit hook
regenerates it and fails if the committed file differs. The doc is an
artifact; group_vars remain the single source of truth.

## Verification

- **Existing monitoring is the regression net:** Prometheus scrapes every
  exporter on every host and blackbox probes every service front door —
  over-blocking surfaces as alerts within minutes of an apply.
- ufw logging (low) puts drops in journald, which Alloy ships to Loki.
- **Manual drill after each host's rollout:** positive — every service on the
  host reachable from a trusted device; negative — a restricted port times out
  from a disallowed source (e.g. node_exporter on valen from a non-monitoring
  host, NFS from a non-client).

## Rollout order

Operator-paced with `--limit`, least critical first, proving the pattern
before the expensive hosts:

1. `pi-cm5-3` (spare) → 2. `pi-cm5-4` (desktop) → 3. `pi-cm5-2`
   (Nextcloud/Vaultwarden) → 4. `pi-cm5-1` (ingress/monitoring/Authentik) →
   5. `valen` (storage/media/Garage) → 6. `beelink` (offsite, last, once the
   pattern is proven).

Steady-state runs are `hosts: all` via `make security` / `site.yml`.

## Implementation process

Cheap agents do the legwork, overseen and verified at each step:

1. **Port sweep** (parallel Explore agents): one sweeps roles/templates/
   group_vars for listeners and Docker publishes; one sweeps the non-Docker
   infrastructure playbooks (Traefik, Garage, NFS, WireGuard, monitoring
   stack, Loki, Alloy) for ports and their legitimate clients. Cross-checked
   against live `ss -tlnup` output (read-only ad-hoc) before being trusted.
2. **Seed the data**: translate the verified inventory into `firewall_rules_*`
   entries and `firewall_source_aliases`.
3. **Build**: role, playbook, `security.yml` import, generator script,
   pre-commit hook.
4. **Rollout**: host-by-host per the order above; the operator runs the
   playbooks (exact commands provided per host), monitoring + drills verify.

## Out of scope / deferred

- **Egress filtering** — revisit once inbound is bedded in; the rule schema
  does not need to change to add it later.
- **SSH hardening** — the next `security`-layer function playbook after this.
- **Fixing the AAAA leak** — unrelated open follow-up, unchanged by this work.
- **Router/zone changes** — none; this is purely host-level.

## Risks & accepted trade-offs

- **SSH open to the barn LAN on beelink** (untrusted neighbors): accepted —
  key-only auth, and it is the only recovery path when the WireGuard tunnel is
  down short of a 1.5 h drive. SSH hardening will tighten this further.
- **Two rule dialects** (ufw commands + iptables snippet in `after.rules`):
  accepted wart of the ufw approach; both are generated from the same rule
  data, so there is one authoring surface.
- **ufw reload briefly flushes DOCKER-USER extras**: rules are re-applied in
  the same reload; the window is milliseconds and inbound-only.
- **A missed listener means a broken service, not an exposure** (default
  deny): the port sweep plus the monitoring net makes this loud and quick to
  fix.
