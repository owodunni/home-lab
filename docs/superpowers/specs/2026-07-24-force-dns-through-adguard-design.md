# Force Home-zone Devices Through AdGuard — Design Spec

**Date:** 2026-07-24
**Status:** Layer 3 (AdGuard-side: anti-DoH filter + `blocking_mode: nxdomain`
for the Firefox canary) implemented in `group_vars/adguard/`. Layers 1–2 (UniFi
DNAT `:53` redirect + `:853` block) pending manual apply — see runbook below.
**Author:** Alexander Poole (with Claude)
**Builds on:** [AdGuard DNS filter](2026-07-24-adguard-dns-filter-design.md),
[Network Zone Segmentation](2026-07-15-network-zone-segmentation-design.md)

## Goal

Make Home-zone devices **actually use** AdGuard for DNS, closing the gap in the
AdGuard design where AdGuard is only the **router's upstream**. That model is
*filter-by-default*, not *filter-by-force*: DHCP hands each device the router as
its resolver, but nothing stops a device from ignoring that and resolving
elsewhere. A curious teenager, a hardcoded smart-TV, or a browser with "Secure
DNS" switched on escapes every blocklist and parental control we deployed.

This spec forces the three realistic escape routes back onto AdGuard:

1. **Manual plain DNS** — a device set to `8.8.8.8` (or any external resolver).
2. **DoT (DNS-over-TLS, port 853)** — an OS/app resolver speaking encrypted DNS.
3. **DoH (DNS-over-HTTPS, port 443)** — a browser resolving over HTTPS.

## Non-goals

- **Privacy from the ISP.** This is content *filtering*, not anonymity. Even
  when every device is forced through AdGuard (which forwards over DoH), the TLS
  **SNI** and destination IPs of each subsequent connection still leak to the
  ISP. Out of scope here — see [ISP privacy](#isp-privacy-what-this-hides-and-what-still-leaks)
  for why, and what actually closing it would take.
- **Raw per-device DNS.** Devices continue to be steered via the router; we do
  not repoint every client's DNS at AdGuard directly. (Same stance as the
  AdGuard spec.)
- **Homelab-zone enforcement.** Homelab hosts are trusted and Ansible-managed,
  and they *must* stay exempt (see "Why Homelab is exempt" below).
- **Perfect DoH elimination.** Per the decision below we take the code-only DoH
  defense, which knocks out the common browsers but not every obscure endpoint.
  Accepted residual risk.

## Scope

| In scope | Out of scope |
|---|---|
| **Home zone** — VLAN 10, `192.168.10.0/24` (all WiFi clients: laptops, phones, TV, IoT) | Homelab zone (`192.168.1.0/24`) — exempt by design |
| Plain DNS (:53) enforcement | Barn / WireGuard path (`192.168.2.0/24`) |
| DoT (:853) enforcement | IPv6 DNS (Home VLAN hands out no IPv6 — see Assumptions) |
| DoH (:443) mitigation (AdGuard-side) | DNSSEC, per-client filtering policies |

## ISP privacy: what this hides, and what still leaks

Encrypted DNS buys less ISP privacy than people expect. This design — AdGuard
forwarding over DoH, plus forcing every device through it — hides your DNS
*lookups* (the ISP sees an encrypted 443 flow to Cloudflare/Quad9, not the
domains). But two things still leak regardless:

- **TLS SNI.** Every HTTPS connection's ClientHello carries the destination
  hostname in **plaintext**. The ISP reads it and knows every site you visit,
  even with encrypted DNS.
- **Destination IPs + metadata.** The ISP still sees which IPs you connect to,
  packet sizes, and timing (revealing for sites on dedicated IPs; less so behind
  big shared CDNs).

**Why we don't chase SNI here.** The usual fix — Encrypted Client Hello (ECH) —
is per-browser and per-destination (only ECH-capable CDNs), and it only
activates when the browser's own DoH is on, which **Layer 3 deliberately
disables**. ECH therefore pulls directly against the filtering goal: you cannot
force all devices through AdGuard *and* rely on browser ECH at once. Marginal,
conflicting, and not a network-level lever — so it is not pursued.

**What real ISP privacy would take (deferred).** The only network-level,
all-traffic fix is a **VPN egress tunnel**: UniFi policy-based routing sending
the Home zone (VLAN 10) out through a commercial WireGuard provider, so the ISP
sees only encrypted traffic to a single endpoint — SNI, IPs, and metadata all
inside the tunnel. Deliberately deferred as its own project because:

- It **shifts trust** from the ISP to the VPN provider — privacy is relative,
  not absolute.
- Throughput cost, subscription cost, and VPN-IP blocks/CAPTCHAs on some sites
  (streaming, banking).
- **Homelab must stay direct** — a VPN egress would break inbound
  Nextcloud/Jellyfin (Cloudflare/Traefik), split-horizon DNS, and the barn
  WireGuard tunnel. It would be Home-zone-only.

Recorded as a future follow-up; this spec stops at DNS-layer filtering.

## Current state (the bypass gap)

```
Compliant device ─DHCP─▶ router (192.168.1.1) ─upstream─▶ AdGuard ─DoH─▶ Cloudflare/Quad9
Escaping device  ────────────────────────────────────────────────────▶ 8.8.8.8 / DoH / DoT
                 (ignores the DHCP-assigned resolver; never touches AdGuard)
```

Only DHCP steers a device to the router. A device that overrides it — or a
browser that resolves over its own DoH — sees **no filtering at all**.

## Design

Three enforcement layers, one per escape route. Two live on the **UniFi router**
(not Ansible-managed — documented here as a runbook, exactly like the
network-zone-segmentation spec, which also touched no Ansible). One lives in
**code** in `group_vars/adguard/`.

### Layer 1 — Plain DNS (:53): transparent DNAT redirect to the router

A UniFi **Destination NAT** rule on the Home zone: any outbound TCP/UDP packet
to port **53** whose destination is **not** the gateway is rewritten to the
**gateway's own DNS** (`192.168.10.1`). The gateway then resolves the query
through its configured upstream — AdGuard — so the device is filtered whether it
asked the router or `8.8.8.8`.

```
Home device ─▶ 8.8.8.8:53  ──DNAT dst→gateway──▶ router DNS ─upstream─▶ AdGuard
(device believes it reached 8.8.8.8; UniFi statefully reverses the reply)
```

**Why redirect to the gateway, not to AdGuard directly.** AdGuard is already the
router's upstream, so pointing the redirect at the gateway means:

- **No AdGuard firewall change.** `firewall_rules_adguard` still allows `:53`
  only from the router — Home devices never talk to pi-cm5-3 directly, so no new
  cross-zone Home→Homelab flow and no widening of AdGuard's exposure.
- **No self-loop risk.** The redirect is scoped to Home-zone *sources*, so
  Homelab traffic — including AdGuard's own bootstrap `:53` queries to
  `1.1.1.1`/`9.9.9.9` — is never rewritten.
- **Split-horizon still works.** The gateway holds the `*.jardoole.xyz`
  A-records and forwards everything else to AdGuard, so redirected clients get
  both internal names and filtering.

**Why transparent redirect over a hard block (decided):** a device hardcoded to
an external resolver keeps working — it is silently filtered instead of losing
DNS entirely. Critical for IoT/TVs that ignore DHCP and cannot be reconfigured.

### Layer 2 — DoT (:853): block

A UniFi firewall rule dropping outbound **:853** from the Home zone. A resolver
attempting DNS-over-TLS fails its handshake and falls back to system DNS — which
Layer 1 now redirects. Safe because, once AdGuard is the enforced resolver,
there is no legitimate outbound DoT left on the Home zone.

### Layer 3 — DoH (:443): AdGuard-side, in code

Port 443 DoH is indistinguishable from normal HTTPS, so it cannot be blocked by
port. Per the **code-only** decision, two additions to `group_vars/adguard/`
(deployed with `make app service=adguard`, no router upkeep):

1. **Anti-DoH blocklist filter.** Add **HaGeZi's Encrypted DNS/VPN/TOR/Proxy
   Bypass** (`filter_52`, the AdGuard-vetted Hostlists Registry list for this) to
   `adguard_filters`. AdGuard null-routes those DoH/DoT/VPN/proxy hostnames, so a
   browser's DoH bootstrap fails and it falls back to system DNS (redirected by
   Layer 1).
2. **Firefox canary — via `blocking_mode: nxdomain`.** Firefox queries
   `use-application-dns.net` before enabling auto-DoH and stays off DoH only on an
   **NXDOMAIN** answer. That canary domain is already carried by the `filter_52`
   list, but AdGuard's default block answers `0.0.0.0` — which looks like a valid
   record and leaves Firefox DoH *on*. So we set `dns.blocking_mode: nxdomain`
   (`adguard_blocking_mode`), which makes the blocked canary return NXDOMAIN and
   actually signal Firefox. Side benefit: every blocked ad fails fast instead of
   hanging on a `0.0.0.0` connection. (Verified against current AdGuard Home docs:
   Hostlists Registry catalog + the blocking-mode reference.)

**Residual (accepted):** a browser pointed at a DoH endpoint *not* on the
blocklist, or an app with a hardcoded DoH server on 443, still escapes. This is
the deliberate trade of the code-only choice over router-side DoH-IP blocking
(rejected: manual IP-list upkeep + CDN over-block risk).

## Why Homelab is exempt (and must stay so)

The redirect is scoped to Home-zone sources only. If it also caught Homelab:

- **AdGuard would loop on itself.** AdGuard's bootstrap `:53` queries (resolving
  its own DoH endpoints at startup) would be redirected back into the resolver
  chain, breaking cold-start.
- **No benefit.** Homelab hosts are Ansible-managed and already point at the
  router by DHCP; there is no untrusted actor to force.

Homelab hosts keep resolving exactly as today.

## Config-as-code boundary

| Piece | Where it lives | Managed by |
|---|---|---|
| DNAT :53 redirect (Home → gateway) | UniFi controller | Manual (runbook below) |
| Block :853 (Home) | UniFi controller | Manual (runbook below) |
| Anti-DoH blocklist filter | `group_vars/adguard/main.yml` | Ansible |
| Firefox canary block | `group_vars/adguard/` + template | Ansible |

The router pieces are UI/controller state, consistent with the
network-zone-segmentation spec. The AdGuard pieces are code, consistent with the
AdGuard spec's "config-as-code, UI is read-only" model.

## Assumptions to confirm at implementation

- **Home VLAN gateway IP** is `192.168.10.1` (VLAN 10 = `192.168.10.0/24` per the
  zone-segmentation spec).
- **Home VLAN hands out no IPv6** (the zone-segmentation spec mandates this for
  new VLANs, precisely because of the AAAA leak). If IPv6 is ever enabled on
  VLAN 10, this design needs a parallel IPv6 `:53` redirect and `:853` block, or
  devices will resolve over IPv6 DNS unfiltered.
- AdGuard remains the router's sole configured upstream.

## Testing / verification

From a **Home-zone** device:

1. **Redirect works:** set the device's DNS manually to `8.8.8.8`, then resolve a
   known-blocked domain (`nslookup doubleclick.net`) — it must still be blocked,
   and the query must appear in AdGuard's query log (`make adguard-ui`).
2. **External resolver captured:** `dig @1.1.1.1 example.com` returns an answer
   sourced from AdGuard (visible in the query log), not Cloudflare directly.
3. **DoT blocked:** `kdig -d @1.1.1.1 +tls example.com` fails/times out (:853
   dropped).
4. **DoH neutralised:** Firefox with "Secure DNS" enabled falls back to system
   DNS (canary), and resolving a public DoH endpoint hostname is blocked.
5. **Split-horizon intact:** `nslookup jellyfin.jardoole.xyz` resolves to valen's
   LAN IP.

From a **Homelab** host (regression):

6. AdGuard cold-starts cleanly and its query log flows — proving the Homelab
   exemption prevents the bootstrap self-loop.

## Recovery / break-glass

This enforcement **raises AdGuard's blast radius**: today a device could
self-rescue by setting manual DNS; once the redirect is live it cannot. So:

- **AdGuard/redirect misbehaves and Home devices lose DNS:** disable the DNAT
  redirect rule in UniFi. Devices fall back to the DHCP-assigned router DNS
  (and, if AdGuard itself is down, revert the router's upstream to `1.1.1.1` per
  the AdGuard spec's break-glass — internet resolves, internal names via public
  Cloudflare until AdGuard returns).
- **DoT block over-broad:** disable the `:853` rule; nothing else depends on it.
- pi-cm5-3 is on the always-on fleet covered by host-resilience (self-heal +
  watchdog), which mitigates the raised blast radius.

## Deployment order

1. **AdGuard code first** (Layer 3): add the anti-DoH filter + Firefox canary to
   `group_vars/adguard/`, deploy `make app service=adguard`, confirm resolution
   still works. Doing this before the router redirect means no window where DoH
   is the only escape and it is already being closed.
2. **UniFi DNAT :53 redirect** (Layer 1): apply Rule 1 in the UniFi runbook
   below, run tests 1–2 and 5–6.
3. **UniFi :853 block** (Layer 2): apply Rule 2 in the UniFi runbook below, run
   test 3.
4. **Full test matrix**, including the Homelab regression (test 6).

## UniFi runbook (Layers 1–2, manual)

These two rules live on the UniFi controller, not in Ansible (same posture as the
network-zone-segmentation spec). Menu paths shift between UniFi Network versions;
the **field values** below are what matter. Apply in order and run the cited
tests after each. Layer 3 (AdGuard) must already be deployed first.

### Rule 1 — DNAT `:53` redirect (force plain DNS to the gateway)

A Destination NAT rule that transparently rewrites Home-zone DNS to the gateway's
own resolver, which forwards to AdGuard.

| Field | Value |
|---|---|
| Type | Destination NAT (DNAT) — the "redirect/force DNS" NAT rule |
| Source zone / network | **Home** (VLAN 10, `192.168.10.0/24`) |
| Protocol | TCP **and** UDP |
| Match destination port | `53` |
| Match destination address | **any EXCEPT `192.168.10.1`** (the gateway) |
| Translated (new) destination | `192.168.10.1:53` (the gateway's DNS) |

- Excluding the gateway as a destination keeps the rule idempotent — it never
  rewrites a query that already targets the gateway onto itself.
- Target is the gateway itself, so **no SNAT/masquerade is needed**: UniFi
  reverses the DNAT statefully and the client sees the reply as if from `8.8.8.8`.
- Scoped to the Home zone as **source**, so Homelab (including AdGuard's own
  bootstrap `:53`) is never rewritten — this is the self-loop guard.
- If your UniFi version does not offer "TCP/UDP" in one rule, create two
  identical rules, one per protocol.

**Verify:** tests 1, 2, 5, and the Homelab regression (test 6).

### Rule 2 — Block `:853` (kill DoT / DoQ)

A zone firewall rule dropping encrypted-DNS-on-853 so those clients fall back to
the now-redirected `:53`.

| Field | Value |
|---|---|
| Type | Zone firewall rule, **Home → Internet/WAN** |
| Action | **Drop** (or Reject) |
| Protocol | TCP **and** UDP |
| Match destination port | `853` |
| Match destination | Any (Internet) |

- Covers both DoT (TCP 853) and DNS-over-QUIC (UDP 853).
- Must sit **above** any general "Home → Internet allow" rule so the drop wins.
- Nothing legitimate uses `:853` once AdGuard is the enforced resolver.

**Verify:** test 3.

### Rollback (either rule)

- **Disable Rule 1** → Home devices fall back to their DHCP-assigned resolver (the
  gateway) as before; if AdGuard itself is down, also revert the router's upstream
  to `1.1.1.1` (AdGuard spec break-glass).
- **Disable Rule 2** → DoT/DoQ is simply allowed again; nothing else depends on it.

## Out of scope / YAGNI

- Router-side DoH-IP blocking (rejected — maintenance + over-block risk).
- Per-device or per-VLAN differentiated DNS policy.
- IPv6 enforcement (blocked upstream by the no-IPv6-on-VLAN-10 assumption).
- Fixing the AAAA/split-horizon leak — a separate long-standing follow-up; this
  spec only depends on VLAN 10 continuing to hand out no IPv6.
- Automating the UniFi rules as code (no UniFi-as-code exists in the repo today;
  same manual posture as network-zone-segmentation).
- **VPN egress for ISP privacy** (hiding SNI + destination IPs) — deferred as its
  own project; see [ISP privacy](#isp-privacy-what-this-hides-and-what-still-leaks).
