# Jellyfin Barn Relay — Design Spec

**Date:** 2026-07-18
**Status:** Proposed
**Author:** Alexander Poole (with Claude)

## Goal

Let a Samsung TV on beelink's local barn network reach Jellyfin (running on
`valen`, at home) using beelink's existing WireGuard tunnel — without touching
the barn router, without changing the TV's network settings, and without any
public DNS changes.

## Why a direct route doesn't work

The barn's local network is `192.168.1.0/24` — the same subnet as the home LAN
(see `wireguard-subnet-collision` history). beelink resolves this collision for
itself via a pinned `/32` route to the barn gateway (`wg_local_gateway`) plus
`wg_allowed_ips` routing the rest of `192.168.1.0/24` over `wg0`. A TV on the
barn network has no such routing and no way to get it (no static routes on a
Samsung TV, no admin access to the barn router today), so it can never resolve
or reach `valen`'s real address (`192.168.1.197`) directly. Traffic has to be
proxied through beelink, which already has a working path home.

## Why no new DNS or router changes are needed

Two approaches were ruled out first:

- **Public Cloudflare DNS record pointing at beelink's private barn IP** —
  works only by coincidence of subnet numbering, and many public resolvers
  (1.1.1.1, Quad9, browser Private Network Access checks) explicitly refuse to
  return private/RFC1918 addresses for public hostnames ("DNS rebinding"
  protection). Would also affect resolution of `jellyfin.jardoole.xyz`
  globally, not just for the barn.
- **Local resolver (dnsmasq) on beelink + manual DNS server on the TV** —
  works, but requires touching the TV's network settings, which was ruled out.

Instead: the TV enters beelink's raw IP directly into the Jellyfin app's manual
"Add Server" field (no DNS involved on the TV side at all). beelink's own
Traefik terminates that connection and relays it to valen over the tunnel.

## Architecture

```
TV (barn LAN) --HTTPS, raw IP, cert warning-->  beelink Traefik
                                                      |
                                          resolves jellyfin.jardoole.xyz
                                          via beelink's own /etc/hosts
                                          -> 192.168.1.197, routed over wg0
                                                      v
                                          valen Traefik (existing router,
                                          Host(jellyfin.jardoole.xyz),
                                          unmodified) --> Jellyfin :8096
```

beelink is already an ACME wildcard-cert (`*.jardoole.xyz`) ingress node
(`[ingress]` in `hosts.ini`), so it can terminate TLS for
`jellyfin.jardoole.xyz` without any certificate work of its own. The one
wrinkle: the TV connects by raw IP, so its TLS ClientHello carries no SNI (SNI
cannot legally be an IP literal, so well-behaved clients omit it). Traefik
supports a **default fallback certificate** for exactly this case
(`tls.stores.default.defaultGeneratedCert`), so beelink can still present its
real wildcard cert. A browser accepts this with a one-time hostname-mismatch
warning — but **testing found the native Jellyfin TV app hard-fails on it with
no click-through option** (unlike a browser), so there is a second, TLS-free
path: a plain-HTTP entrypoint (`:8096`) carrying the identical catch-all relay
with no certificate involved at all. Barn-local only, so dropping TLS on this
one path doesn't expose anything the HTTPS path didn't already.

## Components

**1. `/etc/hosts` entry on beelink only**

```
{{ hostvars[groups['jellyfin'] | first].ansible_host }} jellyfin.jardoole.xyz
```

Resolves today to `192.168.1.197 jellyfin.jardoole.xyz`, but the value is
looked up from `hostvars` of the `jellyfin` group's host at render time, not
hardcoded — this stays correct with no edit if Jellyfin ever moves to a
different host. Exists solely so Traefik's outbound leg to valen resolves the
hostname (and derives the correct TLS SNI from it) instead of dialing a bare
IP. Never exposed to the barn network or any DNS system — pure host-local
override.

**2. New inventory group `[jellyfin_relay]` → `beelink`**

Follows the existing "each concern gets its own group" convention (mirrors
`[backup_mirror]`). A one-line `hosts.ini` change if the offsite relay point
ever moves.

**3. New function playbook `playbooks/jellyfin-relay.yml`**

`hosts: jellyfin_relay`. Two tasks:
- Add the `/etc/hosts` line above.
- Deploy a new Traefik dynamic conf file to
  `/etc/traefik/conf.d/jellyfin-relay.yml` on beelink:

```yaml
tls:
  stores:
    default:
      defaultGeneratedCert:
        resolver: letsencrypt
        domain:
          main: "{{ traefik_domain }}"
          sans: ["*.{{ traefik_domain }}"]

http:
  routers:
    jellyfin-relay:
      entryPoints: ["websecure"]
      rule: "PathPrefix(`/`)"   # catch-all: TV connects by raw IP, no Host to match
      service: jellyfin-relay
      tls: {}
    jellyfin-relay-plain:      # same relay, no TLS — see "Plain-HTTP fallback" below
      entryPoints: ["jellyfin-relay-plain"]
      rule: "PathPrefix(`/`)"
      service: jellyfin-relay
  services:
    jellyfin-relay:
      loadBalancer:
        passHostHeader: false   # forces Host: jellyfin.jardoole.xyz to the backend
        servers:
          - url: "https://jellyfin.jardoole.xyz:443"
```

The `jellyfin-relay-plain` entrypoint (`:8096`) is defined in
`traefik-static.yml.j2`, gated behind `{% if 'jellyfin_relay' in group_names %}`
so it only exists on beelink, not on other `[ingress]` hosts. See "Plain-HTTP
fallback" below.

Imported into the `applications` layer aggregator, right after `jellyfin.yml`
— it exposes that app to a second network, so it belongs with it thematically.
No hard ordering dependency on `jellyfin.yml` itself (this playbook doesn't
read any state Jellyfin's deploy produces), but ingress (Traefik on beelink)
must already be up, which the existing layer order guarantees.

**4. `wg0.conf.j2` (networking layer, discovered during testing): a routing
fix on beelink, not a relay-specific change.** valen's existing
`Host(jellyfin.jardoole.xyz)` router needs no changes — it already does the
right thing once it receives a request with that Host header — but reaching
beelink at all from a barn-local peer (the TV, or anyone testing from a
laptop) turned out to be broken independently of the relay: beelink's own
`wg_allowed_ips` route for `192.168.1.0/24` (metric 0, via `wg0`) beats the
local `wlo1` DHCP route for every address in that /24 except the one `/32`
already pinned for the barn gateway. So any reply beelink sends to a barn-local
peer other than the gateway — regardless of Traefik or this feature — was
getting routed into the tunnel instead of answered locally, and silently
dropped. Confirmed directly: `ip route get <barn-peer-ip>` on beelink showed
`dev wg0 src 192.168.2.5` instead of `dev wlo1`.

Fixed by extending the existing gateway-pin pattern in `wg0.conf.j2` with
source-based policy routing: a second table (100) holds only the local,
non-tunnel path for `192.168.1.0/24`, and an `ip rule` sends any packet already
sourced from beelink's own WiFi address through it. This only affects replies
to traffic beelink *receives* locally — connections beelink itself initiates
(e.g. the relay's own hop to valen) are unaffected, since a new connection's
source address isn't fixed until after the routing decision the fix targets.
Without this, the relay would work for nothing on the barn network, TV
included — it is a prerequisite for this design, not an optional hardening
step.

**5. Plain-HTTP fallback (discovered during TV testing): a second, TLS-free
entrypoint on beelink.** With the routing fix in place, a browser hitting
`https://<beelink-barn-ip>` worked correctly — but the actual TV's native
Jellyfin app reported "connection failed" against the same URL. Root-caused by
comparing a no-SNI `curl` against the working browser request: both got a
valid response from Traefik (confirming the relay itself was fine), but a
browser silently accepts the `defaultGeneratedCert` fallback's hostname
mismatch with a click-through warning, while the native TV client validates
the cert strictly and hard-fails with no override. Fixed by adding a second
entrypoint, `jellyfin-relay-plain` on `:8096` (`traefik-static.yml.j2`, gated
to beelink only), carrying an unencrypted duplicate of the same catch-all
router. No certificate is involved on this path at all, so there is nothing
for the TV app to reject. The existing HTTPS path is unchanged and still
scoped explicitly to `websecure` (routers with no `entryPoints` listed
otherwise bind to every entrypoint by default, which would have pulled in the
new plain one too).

## Request flow

1. TV → `https://<beelink-barn-ip>` — TLS ClientHello, no SNI.
2. beelink's `websecure` entrypoint has no SNI to match a specific router's
   cert, so it serves the `defaultGeneratedCert` (the real `*.jardoole.xyz`
   wildcard). Client shows a hostname-mismatch warning; user accepts once.
3. HTTP layer: no `Host`-based router matches (TV didn't send
   `jellyfin.jardoole.xyz`), so the catch-all `jellyfin-relay` router matches
   and sends the request to the `jellyfin-relay` service.
4. Service dials `https://jellyfin.jardoole.xyz:443`. beelink's own
   `/etc/hosts` resolves this to `192.168.1.197`; `wg_allowed_ips` sends it
   over `wg0`. SNI is derived automatically from the URL's hostname, so this
   hop performs full, unmodified TLS certificate validation against valen's
   cert — no warnings here.
5. `passHostHeader: false` means the request valen's Traefik receives has
   `Host: jellyfin.jardoole.xyz`, matching its existing router exactly.
   Response flows back through the same chain.

## Explicitly out of scope

- **Access restriction on the relay.** The barn WiFi is open (no PSK), so
  anything joining it could also reach the relay today. A future firewall
  project (already planned, not part of this spec) will restrict this to the
  TV's IP across all hosts. Jellyfin's own login is the only gate until then.
- **DNS for the TV.** Deliberately not solved here — the TV always connects by
  raw IP. If the barn router later turns out to support local DNS overrides or
  a friendlier DHCP-DNS setup, that's a separate follow-up, not required for
  this design to work.
- **beelink's barn IP changing.** If beelink's DHCP-assigned barn address ever
  changes, only the value entered in the TV's Jellyfin app needs updating —
  nothing in this design depends on that IP staying fixed (the `/etc/hosts`
  entry and Traefik config never reference it).

## Testing

- From beelink (via the tunnel, e.g. `ansible beelink -a "ip route get <barn-peer-ip>"`):
  confirm the route is `dev wlo1`, not `dev wg0 src 192.168.2.5` — verifies the
  policy-routing fix from item 4 above before testing anything relay-specific.
- From beelink itself: `curl -vk https://jellyfin.jardoole.xyz` should return
  Jellyfin's login page with a valid cert chain (verifies the `/etc/hosts` +
  tunnel routing + valen's router).
- From a device on the barn LAN (or beelink itself hitting its own barn IP):
  `curl -vk https://<beelink-barn-ip>` should return the same page, with a
  cert presented for `*.jardoole.xyz` (verifies the fallback cert + catch-all
  router + Host-header rewrite).
- Same, but no-SNI and plain HTTP, to mimic the TV exactly:
  `curl -vk http://<beelink-barn-ip>:8096` should return the same page with no
  certificate involved (verifies `jellyfin-relay-plain`).
- On the TV: add `http://<beelink-barn-ip>:8096` as a server in the Jellyfin
  app — no certificate warning to accept, since this path is unencrypted —
  confirm login and playback. (`https://<beelink-barn-ip>` also works from a
  browser, with a one-time cert warning, but native TV apps were found to
  hard-fail on that warning with no override — hence the plain-HTTP path.)
