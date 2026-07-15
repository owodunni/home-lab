# Network Zone Segmentation — Design Spec

**Date:** 2026-07-15
**Status:** Approved design, pre-implementation
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
**source-IP allow-rules**, which requires each privileged device to have a
**DHCP reservation** (stable IP).

1. **`trusted-clients` (IP group) → Homelab: allow**
   - `trusted-clients` = desktop + laptops + phones (their reserved IPs).
   - One rule covers the whole personal fleet; maintenance = editing group
     membership as devices come and go.
2. **`TV-IP → 192.168.1.197 tcp/443`: allow**
   - Jellyfin's front door via `valen`'s Traefik.
3. **Home → Homelab: block** (backstop) — IoT gadgets and any un-listed device
   die here.

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
its IP added to `trusted-clients`. This is the ongoing tax of the merged model —
the work a separate Trusted VLAN would have done implicitly by SSID membership.

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

## Cutover order

1. **Create VLAN 10** network `192.168.10.0/24`, DHCP on, **IPv6 off**.
2. **Gather MACs** of desktop, laptops, phones, TV (UniFi already lists them as
   current clients).
3. **Pre-create DHCP reservations** (fixed IPs) on VLAN 10 for those devices by
   MAC, so their IPs are known before they move.
4. **Build the `trusted-clients` IP group** (desktop + laptops + phones) and note
   the TV's reserved IP.
5. **Define zones** (Homelab ⊇ default LAN; Home ⊇ VLAN 10) and the **firewall
   policies** from the Firewall + Exceptions sections.
6. **Retarget the SSID** from the default LAN to VLAN 10 — the cutover moment;
   WiFi clients reconnect onto VLAN 10.
7. **Verify** (acceptance criteria below).

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

Repoint the SSID back to the default LAN. The network returns to flat instantly;
the zones and firewall policies sit inert with nothing in the Home zone. Created
VLAN 10, reservations, and IP groups can be deleted at leisure.

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
