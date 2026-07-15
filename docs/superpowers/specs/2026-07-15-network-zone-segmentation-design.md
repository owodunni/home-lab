# Network Zone Segmentation — Design Spec

**Date:** 2026-07-15
**Status:** Implemented & verified 2026-07-15 (positive + negative ping tests
against `valen` from a trusted vs. de-listed device)
**Author:** Alexander Poole (with Claude)

## Goal

Shrink the homelab's attack surface by moving every non-homelab device off the
flat LAN and gating access back into the homelab down to two narrow paths. The
homelab keeps its current subnet; **everything that is not the homelab moves**.

Concretely, only two ingress paths into the homelab survive:

1. **Trusted personal devices** (desktop, laptops, phones) → full homelab access.
2. **The TV** → Jellyfin only.

Everything else (IoT gadgets and any un-listed device) has **no** path into the
homelab.

This is a **UniFi Zone-Based Firewall** design (UniFi Network 9.0+). It is a
router/controller configuration change — there are **no changes to the Ansible
repo**, because the homelab retains every IP it has today.

## Current state

- **Flat network:** everything (homelab servers, desktop, laptops, phones, TV,
  IoT) shares the default `192.168.1.0/24` LAN. No VLANs.
- **Homelab hosts are wired**, on `192.168.1.0/24`:
  - `valen` (`192.168.1.197`) — media/arr stack, Jellyfin, Garage S3, NFS,
    co-located Traefik.
  - `pi-cm5-*` — Authentik, Nextcloud, Vaultwarden, monitoring, ingress.
- **`beelink` (`192.168.2.5`)** is the offsite barn node, reachable only over
  **WireGuard** into `192.168.1.0/24`. Not part of this LAN segmentation, but its
  tunnel path must be preserved.
- **All non-server devices are WiFi.**
- **Split-horizon DNS on the UniFi router:** `*.jardoole.xyz` CNAMEs resolve to
  each host's LAN IP via a router A-record override, so internal clients reach
  services directly on the LAN over IPv4.
- **IPv4-only homelab.** (The public AAAA records still point at Cloudflare — the
  known "AAAA leak" — which is why new VLANs must not hand out IPv6.)

## Chosen approach: 2 zones (Homelab / Home)

Considered three structures:

- **A — 3 zones (Homelab / Trusted / IoT):** best isolation; IoT kept off both
  servers and personal devices. Rejected because separating personal devices
  from IoT breaks everyday convenience (printing, casting, phone-controls-IoT)
  and requires cross-zone mDNS reflection.
- **A′ — 3 zones, loosened (`Trusted → IoT` allowed):** keeps homelab isolation
  while restoring convenience. Recommended, but not chosen.
- **B — 2 zones (Homelab / Home) — CHOSEN:** one zone for all non-homelab
  devices; per-device allow-rules govern access into the homelab.

**Conscious trade-off of the 2-zone choice:** personal devices share an L2
segment with IoT gadgets, so there is **no lateral protection** between a
compromised IoT device and a phone/laptop. This is accepted deliberately: the
project's goal is protecting the **homelab**, and the Homelab⇄Home boundary
delivers that. The Trusted/IoT split is a secondary hardening the operator chose
to forgo in exchange for frictionless printing/casting/smart-home (all of which
now happen within a single zone, needing no mDNS reflection).

## Topology

| Zone | Network | Subnet | Members | Assignment |
|---|---|---|---|---|
| **Homelab** | Default LAN (VLAN 1, untagged) | `192.168.1.0/24` *(unchanged)* | `valen`, `pi-cm5-*` | Wired switch ports (native VLAN) — no change |
| **Home** | New VLAN 10 | `192.168.10.0/24` | Desktop, laptops, phones, TV, all IoT | Existing WiFi SSID retargeted to VLAN 10 |

Subnet `192.168.10.0/24` is chosen to avoid collision with `192.168.1.0/24`
(home) and `192.168.2.0/24` (barn).

Because all servers are wired and everything else is WiFi, the cutover is
essentially a single action: **retarget the existing SSID to VLAN 10.** All
wireless devices move to the Home zone at once; wired servers stay in Homelab.

## Firewall policy (default = block, stateful)

Zone-Based Firewall. Return traffic for established/related flows is
auto-allowed; the table below is about which side may **initiate**.

| From ↓ / To → | Homelab | Home | Internet |
|---|---|---|---|
| **Homelab** | allow | block | allow |
| **Home** | **block** *(per-device exceptions below)* | allow | allow |
| **Internet** | block | block | — |

Rationale for `Homelab → Home: block`: servers never need to initiate to
clients; blocking it limits lateral movement if a server is ever compromised.
Replies to client-initiated traffic still flow (stateful).

## Exception rules (Home → Homelab pair, ordered: allows above the block)

In a single flat zone, "specific devices reach the homelab" is enforced by
**per-device allow-rules**, ordered above a catch-all block. Each privileged
device has a **DHCP reservation** (stable IP) so its identity is unambiguous.

As-built in the Policy Engine (`Home → Internal` direction), highest priority
first:

1. **TV → Jellyfin: allow** — Source device `TIZEN …a9:74` (the Samsung TV),
   Destination `192.168.1.197`, TCP/UDP `443`. (Matched by device, which is even
   more stable than the reserved `192.168.10.20`.)
2. **Trusted devices → Internal: allow** — Source = the two trusted clients
   (`Lenovo-T14s` `192.168.10.11`, `Pixel 10 Pro` `192.168.10.12`), Destination
   any, all protocols.
3. **Block all `Home → Internal`** (backstop) — IoT gadgets and any un-listed
   device die here. The zone-matrix default between `Home` and `Internal` is
   *also* block, so this is belt-and-suspenders.

**UI note:** this Policy Engine build does **not** let a policy reference an
`Objects` IP group as its source — source matching is by IP / MAC / **Device** /
Identity. So the `trusted-clients` object we created is unused; devices are
matched directly (by Device for the roster and TV). Keep the DHCP reservations
regardless — they make the Device/IP identities stable.

### Shared-Traefik caveat (TV rule)

`valen` runs Traefik terminating TLS on `:443` for **all** its vhosts (Jellyfin,
Jellyseerr, the *arr apps, `s3.jardoole.xyz`). A network firewall can only open
"`TV → valen:443`" — it **cannot** distinguish Jellyfin from the other vhosts by
hostname. The other vhosts remain protected at the **application layer** by
Traefik forward-auth / Authentik OIDC. The network boundary lands the TV at
valen's front door; app-auth keeps the rest shut.

**Future tightening (out of scope):** for a hard network-level "Jellyfin and
nothing else," bind Jellyfin to a dedicated port/IP outside the shared Traefik
and point the TV rule there.

### Maintenance cost to accept

Every new phone/laptop that should reach the homelab needs a DHCP reservation +
adding to the "Trusted devices → Internal" allow policy (Device or IP). This is
the ongoing tax of the merged model — the work a separate Trusted VLAN would have
done implicitly by SSID membership.

## DNS & IPv6 on the new VLAN

- **DNS:** VLAN 10 uses the UniFi gateway as its DNS server (default). The
  split-horizon overrides live on the router, so `*.jardoole.xyz` resolves to the
  correct homelab LAN IPs from the Home zone identically to today. The TV
  resolving `jellyfin.jardoole.xyz` gets `192.168.1.197`, then exception rule 2
  lets it through. DNS to the gateway is traffic *to the router itself*, not an
  inter-zone flow, so the default-block matrix does not touch it — clients can
  always resolve.
- **IPv6: set to Off / None on VLAN 10.** The homelab is IPv4-only, so this
  changes nothing there, and it guarantees no device on VLAN 10 grabs a public
  AAAA and hairpins out to Cloudflare instead of taking the LAN path. It also
  keeps the firewall matrix honest — no parallel v6 path bypassing the v4 rules.

## Must-preserve (verify post-cutover)

- **WireGuard (barn / beelink):** the tunnel terminates into `192.168.1.0/24`,
  which is untouched. In the Zone-Based Firewall the VPN interface is its own
  zone — confirm its policy to **Homelab stays allow** so beelink's Garage pulls
  and Alloy→Loki shipping keep flowing. Not being changed; just verified.
- **Monitoring:** Prometheus / blackbox on `pi-cm5-1` probe services on `valen`
  and the Pis — all **within** the Homelab zone (intra-zone allowed), so
  unaffected. Verify green after cutover.

## Cutover order (as-built, override-free)

The homelab zone is the **built-in `Internal` zone** (leaving the servers there
auto-preserves the `VPN → Internal` WireGuard policy). The order below moves all
Wi-Fi clients to VLAN 10 *first*, while VLAN 10 is still in `Internal` (so nothing
is isolated and the admin laptop never loses access), then pins IPs and stages the
policies, then flips VLAN 10 into the `Home` zone as the single atomic activation.
This avoids UniFi's per-client **Virtual Network Override** (setting a Fixed IP on
a not-yet-joined network yanks that one client onto the VLAN immediately — not
what we want for staging).

1. **Create VLAN 10** network `192.168.10.0/24`, DHCP on, **IPv6 = None**. It
   lands in the `Internal` zone by default — fine.
2. **Retarget the SSID** (`Hi-Fi`) from the default LAN to VLAN 10. All Wi-Fi
   clients reconnect onto VLAN 10; still `Internal`, so full access, no isolation
   yet, admin laptop keeps talking to the controller.
3. **Pin Fixed IPs** on the trusted devices + TV — now override-free, since
   they're already on the `Home` network. Reconnect each to grab its reserved IP.
4. **Create the `Home` zone empty** (Policy Engine → Zones), and stage the three
   `Home → Internal` **policies** (Exception rules section). Confirm the zone
   matrix shows `Home → Internet` and `Home → Gateway` = **Allow**, and
   `Home ↔ Internal` = **Block**.
5. **Final flip:** assign the VLAN 10 network to the `Home` zone. Isolation
   activates atomically — trusted devices stay in via the allow policy, everyone
   else is walled off, TV gets Jellyfin only.
6. **Verify** (acceptance criteria below).

## Acceptance criteria

- Desktop (in `trusted-clients`) reaches all homelab services (SSH, Nextcloud,
  Vaultwarden, Jellyfin, monitoring UIs).
- A phone/laptop in `trusted-clients` reaches the user-facing services.
- The TV plays Jellyfin (`jellyfin.jardoole.xyz`) and nothing else is usable.
- An IoT device (not in `trusted-clients`) **cannot** reach any homelab host —
  ping and `curl https://valen` both fail.
- WireGuard: beelink still reaches the homelab (Garage pull / Loki push green).
- Monitoring: Prometheus targets and blackbox probes all green.
- No IPv6 address handed out on VLAN 10.

## Rollback

Move the VLAN 10 network's zone back from `Home` to `Internal` (instant
de-isolation — everything shares the homelab zone again), or repoint the `Hi-Fi`
SSID back to the default LAN to return to a fully flat network. The zones and
policies then sit inert. Created VLAN 10, reservations, and the (unused)
`trusted-clients` object can be deleted at leisure.

## Out of scope / future follow-ups

- **Trusted/IoT isolation** (the rejected 3-zone or loosened-3-zone models) — can
  be revisited later without disturbing the Homelab boundary: split the Home zone
  into Trusted + IoT VLANs and move the `trusted-clients` devices onto the
  Trusted SSID.
- **Hard network-level Jellyfin-only** for the TV (dedicated Jellyfin port/IP off
  shared Traefik).
- **Guest network / zone** — not requested.
- **The AAAA leak** on the homelab side — pre-existing, tracked in CLAUDE.md.
- **SSH hardening / firewall on hosts** — separate `security` layer concern.
