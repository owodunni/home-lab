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

**Why block, not redirect (as we do for :53).** The `:53` redirect works
*because plain DNS has no authentication* — the client trusts whatever answer
comes back, so a transparent DNAT to the gateway is invisible. DoT/DoQ is DNS
wrapped in **TLS**: before any query flows, the client validates the server's
**certificate against the hostname it dialed** (`dns.google`,
`cloudflare-dns.com`, sometimes a pinned key). Redirect that connection to
AdGuard and the handshake *fails* — AdGuard can only present its own cert, never
Google's. So a redirect on `:853` yields the **same outcome as a block** (the DoT
attempt dies and the resolver falls back to the now-redirected `:53`), but adds
failure modes a block avoids: a Strict-mode or cert-pinning client gets a TLS
alert instead of a clean fall-through. TLS is *designed* to make transparent
interception detectable, so — unlike `:53` — there is no way for AdGuard to
transparently "answer" `:853`. Blocking is the honest, simpler expression of
"this will fail anyway."

### Layer 3 — DoH (:443): AdGuard-side, in code

Port 443 DoH is indistinguishable from normal HTTPS, so it cannot be blocked by
port. Layer 3 doesn't intercept the DoH traffic itself — it exploits **bootstrap,
the one moment a DoH client is vulnerable.**

**How it gets used (the chicken-and-egg trap).** Before a browser/OS can send a
single DoH query to (say) `mozilla.cloudflare-dns.com`, it must first learn that
hostname's **IP address**. That lookup is ordinary system DNS → the router →
**AdGuard**. `filter_52` null-routes those DoH-provider hostnames, so the bootstrap
lookup fails, the client can't find its DoH server, and it **falls back to system
DNS = AdGuard**. In other words, *a DoH client has to resolve its provider's name
through AdGuard before it can bypass AdGuard* — so the filter fires every time a
client tries to turn DoH on. (Firefox has an even cleaner hook: it queries the
`use-application-dns.net` canary first and, on NXDOMAIN, never attempts DoH at
all.) The **one gap** is an app with a *hardcoded DoH IP* — it skips the hostname
lookup, so nothing routes through AdGuard and Layer 3 can't touch it. That is the
accepted residual below.

Per the **code-only** decision, two additions to `group_vars/adguard/`
(deployed with `make app service=adguard`, no router upkeep):

1. **Anti-DoH blocklist filter.** Add **HaGeZi's Encrypted DNS/VPN/TOR/Proxy
   Bypass** (`filter_52`, the AdGuard-vetted Hostlists Registry list for this) to
   `adguard_filters`. AdGuard null-routes those DoH/DoT/VPN/proxy hostnames, so a
   browser's DoH bootstrap fails and it falls back to system DNS (redirected by
   Layer 1).
2. **Firefox canary — an explicit rule + `blocking_mode: nxdomain`.** Firefox
   queries `use-application-dns.net` before enabling auto-DoH and stays off DoH
   only on an **NXDOMAIN** answer. Two corrections to the original design here,
   both found in implementation:
   - The canary is **not** carried by `filter_52` (verified against the
     downloaded `52.txt`: zero `application-dns` entries). It is blocked
     explicitly via `adguard_blocked_domains`.
   - `blocking_mode` must be rendered under **`filtering:`**, not `dns:` —
     schema 34 reads `filtering.blocking_mode` and silently ignores a `dns:`
     copy, leaving the live answer at the `0.0.0.0` default.

   Side benefit: every blocked ad fails fast instead of hanging on a `0.0.0.0`
   connection.

**iCloud Private Relay (why `nxdomain` is load-bearing, not cosmetic).**
`filter_52` also blocks `mask.icloud.com` / `mask-h2.icloud.com` /
`mask-canary.icloud.com` — correctly, since Private Relay tunnels Safari traffic
and resolves DNS through Apple, bypassing every filter in this design. But the
*answer* matters. Apple's network guidance is explicit: return **NXDOMAIN or
NoError-NoData** for the mask hosts so the device detects the block, alerts the
user and falls back to direct connections — and "avoid causing DNS resolution
timeouts or silently dropping IP packets sent to the Private Relay server, as
this can lead to delays on client devices."

Answering `0.0.0.0` is exactly that failure mode: iOS believes the relay
**resolved** and hangs trying to reach it, so Safari stops loading public pages
altogether while LAN names (`jellyfin.jardoole.xyz`) keep working — Private Relay
never proxies local-network destinations. This was observed in production on an
iPhone before the `filtering.blocking_mode` fix. **Blocking Private Relay without
`nxdomain` breaks Safari.**

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
6. **Blocked domains answer NXDOMAIN, not `0.0.0.0`:** `dig mask.icloud.com`
   must return `status: NXDOMAIN` with no answer section. A `0.0.0.0` A-record
   here means `blocking_mode` is not taking effect (it must be under
   `filtering:`, not `dns:`) and **iPhone Safari will hang on every page** —
   see the Private Relay note under Layer 3. Confirm on an iOS device: Safari
   loads public sites, and iOS reports Private Relay as unavailable on this
   network rather than failing silently.

From a **Homelab** host (regression):

7. AdGuard cold-starts cleanly and its query log flows — proving the Homelab
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
   below, run tests 1–2 and 5–7.
3. **UniFi :853 block** (Layer 2): apply Rule 2 in the UniFi runbook below, run
   test 3.
4. **Full test matrix**, including the Homelab regression (test 7).

## UniFi runbook (Layers 1–2, manual)

These two rules live on the UniFi controller (UniFi Network 9.x, the zone-based
**Policy Engine**), not in Ansible — same posture as the network-zone-segmentation
spec. Menu **labels** shift between versions; the **field values** are what
matter. Deploy Layer 3 (AdGuard) first, then apply these in order and run the
cited tests after each.

**Redirect target (per design decision):** the DNAT redirect points Home DNS at
the **gateway** (`192.168.10.1`), which already forwards to AdGuard as its
upstream. This needs **no firewall changes** and opens nothing new between zones.
Trade-off: AdGuard's query log shows the gateway, not per-device client IPs. (To
get per-device visibility instead, you would translate to AdGuard's IP
`192.168.1.23` directly and then widen `firewall_rules_adguard` to the Home subnet
plus add a Home→AdGuard:53 zone allow — deliberately not chosen here.)

### Prerequisites — reusable objects

Create these once (UniFi **Settings → Profiles**, the IP/Port group objects) so
both rules can reference them by name:

- **Port group `DNS`** — TCP/UDP `53`.
- **Port group `DoT`** — TCP/UDP `853`.
- **IP group `Home Gateway`** — `192.168.10.1` (the Home VLAN's gateway address).
  *(Confirm this is the VLAN 10 gateway — VLAN 10 = `192.168.10.0/24`.)*

### Rule 1 — DNAT `:53` redirect (force plain DNS to the gateway)

NAT translation happens **before** the firewall zones process routing, so this is
a **NAT** policy, not a firewall rule. Go to **Settings → Policy Table** (Policy
Engine) → **Create New Policy**. The first choice is the **policy type** — a list
of `Firewall / Route / QoS / NAT / DNS / ACL / Port Forwarding`; pick **NAT**,
which then reveals the fields below:

| Field | Value |
|---|---|
| Name | `Redirect Client DNS` |
| Type | **Dest. NAT** (Destination NAT) |
| Interface | **Home** (VLAN 10) — the network being forced |
| Protocol | **TCP/UDP** |
| Source → IP | **`Home Gateway`** group, **Match Opposite = ON** — all Home clients *except* the gateway (loop guard) |
| Source → Port | Any |
| Destination → IP | **`Home Gateway`** group, **Match Opposite = ON** — any dest *except* the gateway, i.e. catches external resolvers like `8.8.8.8` |
| Destination → Port | **`DNS`** group (`53`) |
| Translated IP address | `192.168.10.1` (the gateway) |
| Translated port | blank (or `53`) |

The two **Match Opposite** toggles are the crux:

- **Source** inverts the gateway group to "everyone except the gateway", so the
  gateway's own upstream lookups are never captured and looped. (Belt-and-braces:
  the gateway's recursion egresses on the Homelab side, not the Home interface, so
  it would not match anyway — but this makes the intent explicit.)
- **Destination** inverts it to "any address except the gateway", so only queries
  aimed at *outside* resolvers get rewritten; a query already going to the gateway
  is left alone (no pointless self-redirect).

**No SNAT/masquerade is needed:** the target is the clients' own gateway, so the
reply returns through the same device and UniFi reverses the DNAT statefully — the
client sees the answer as if it came from `8.8.8.8`.

**Verify:** tests 1, 2, 5, and the Homelab regression (test 7).

### Rule 2 — Block `:853` (kill DoT / DoQ)

Unlike Rule 1 this is **not** a NAT policy — there is nothing to translate (see
"Why block, not redirect" under Layer 2). It is a plain zone-based **Firewall**
policy that drops encrypted-DNS-on-853 so those clients fall back to the
now-redirected `:53`. Go to **Settings → Policy Table** (Policy Engine) →
**Create New Policy**, and from the **policy type** list
(`Firewall / Route / QoS / NAT / DNS / ACL / Port Forwarding`) pick **Firewall** —
only then does the **Action** field below appear. Set:

| Field | Value |
|---|---|
| Policy type | **Firewall** (chosen from the type list — *not* NAT; there is nothing to translate) |
| Name | `Block DoT` |
| Action | **Block** (Drop — silently discard; no "Reject", so probing clients just time out and fall back) |
| IP version | **IPv4** (VLAN 10 hands out no IPv6; add a parallel IPv6 rule only if that ever changes) |
| Protocol | **TCP/UDP** (one rule covers both DoT-over-TCP and DoQ-over-UDP) |
| Source → Zone | **Home** (VLAN 10) |
| Source → IP | **Any** (every Home client) |
| Source → Port | **Any** |
| Destination → Zone | **Internet / External (WAN)** — DoT/DoQ endpoints are all off-network; scoping to WAN leaves intra-Home and Home→Gateway DNS untouched |
| Destination → IP | **Any** |
| Destination → Port | **`DoT`** group (`853`, TCP + UDP) — the prerequisite Port group |
| Logging | Optional; enable briefly to confirm the rule is catching `:853` attempts, then turn off to avoid log noise |
| Schedule | Always |

- **Both transports in one rule.** TCP `853` = DoT, UDP `853` = DNS-over-QUIC
  (DoQ). The `DoT` port group holds both, so this single policy covers each.
- **Ordering.** In the zone model a Block policy on the `Home → Internet` pair is
  evaluated ahead of a general allow. If your policies are manually ordered, place
  this **above** any broad `Home → Internet: allow`; if UniFi auto-orders by
  specificity, a port-scoped block already outranks a catch-all allow — verify it
  sits above in the Policy Table list.
- **Why WAN, not "any destination".** A device's own gateway (`192.168.10.1`)
  never serves `:853`, and intra-Home traffic is irrelevant, so restricting the
  destination zone to the Internet keeps the rule narrow and can't accidentally
  interfere with LAN/gateway flows.
- Nothing legitimate uses `:853` once AdGuard is the enforced resolver, so there
  is no allow-list carve-out to maintain.

**Verify:** test 3 (`kdig -d @1.1.1.1 +tls example.com` from a Home device must
fail/time out).

### Rollback (either rule)

- **Disable Rule 1** → Home devices resolve via the gateway exactly as before (they
  already use it by DHCP); if AdGuard itself is down, also revert the router's
  upstream to `1.1.1.1` (AdGuard spec break-glass).
- **Disable Rule 2** → DoT/DoQ is allowed again; nothing else depends on it.

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
