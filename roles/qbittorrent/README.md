# qbittorrent role

Deploys qBittorrent behind a ProtonVPN tunnel as a Docker Compose stack on the
media host (valen), and is the first service of the media-stack migration (see
`docs/media-stack-migration.md`).

## What it deploys

Three containers in one stack (`/opt/qbittorrent`):

| Container | Image | Role |
|-----------|-------|------|
| `gluetun` | `ghcr.io/qdm12/gluetun` | VPN tunnel (ProtonVPN/OpenVPN). Owns the netns; publishes the WebUI on `127.0.0.1`. Kill-switch via firewall. |
| `qbittorrent` | `lscr.io/linuxserver/qbittorrent` | Torrent client. `network_mode: service:gluetun` — all traffic egresses the VPN. |
| `port-manager` | `snoringdragon/gluetun-qbittorrent-port-manager` | Reads gluetun's NAT-PMP forwarded port and sets it as qBittorrent's listen port. |

- WebUI: `https://qbittorrent.jardoole.xyz` via Traefik, gated by Authentik
  forward-auth.
- Config: `/opt/qbittorrent/config` (local bind). Data: `/mnt/storage/media` →
  `/data` (shared pool, for hardlinks).

## Prerequisites

- valen in `[services]` (Docker), `[ingress]` (Traefik), `[media]` (shared vars).
- `playbooks/media-storage.yml` has created `/mnt/storage/media/torrents/*`.
- `playbooks/media-forward-auth.yml` deployed + the Authentik domain-level
  forward-auth provider/application created.
- Vault secrets in `group_vars/qbittorrent/vault.yml` (via `/vault`):
  - `vault_protonvpn_username` — **must** end in `+pmp`
  - `vault_protonvpn_password`
  - `vault_qbittorrent_password`

## First-run setup (manual, in the WebUI)

LinuxServer.io qBittorrent 5.x sets a random temporary WebUI password on first
start. After `playbooks/qbittorrent.yml` runs:

1. `docker logs qbittorrent` on valen → copy the temporary password.
2. Log in at `https://qbittorrent.jardoole.xyz` (through Authentik first).
3. **Options → Web UI → Authentication**:
   - Set the permanent password to `vault_qbittorrent_password`.
   - Enable **Bypass authentication for clients on localhost** — lets the
     port-manager sidecar (which reaches qBittorrent over `127.0.0.1` in the
     shared netns) update the forwarded port without credentials.
   - Enable **Bypass authentication for clients in whitelisted IP subnets** and
     add **`172.28.0.0/16`** (the compose `media` network / `qbittorrent_docker_subnet`).
     This skips qBittorrent's own login for the Traefik-proxied browser path:
     Traefik reaches qBittorrent via the loopback-published port, and Docker's
     proxy rewrites the source IP to the `media` bridge gateway (`172.28.0.1`),
     **not** your LAN IP — so a `192.168.x` whitelist never matches. Authentik is
     already the single auth layer in front, so this is safe (the port is
     loopback-only). To find the exact IP, watch `docker logs -f qbittorrent`
     while loading the page.
4. **Options → Downloads**: set default save path `/data/torrents`, and add
   categories `movies` → `/data/torrents/movies`, `tv` → `/data/torrents/tv`,
   incomplete → `/data/torrents/incomplete`.
5. (Optional) seeding limits: ratio 2.0 / 7 days, then pause.

## Validation gate

- VPN egress: `docker exec gluetun wget -qO- https://ipinfo.io/ip` (or `curl`)
  shows a ProtonVPN IP, **not** the home IP.
- Port forwarding: `docker exec gluetun cat /tmp/gluetun/forwarded_port` is
  non-empty; qBittorrent's listen port (Options → Connection) matches it.
- Kill-switch: stopping gluetun makes qBittorrent lose connectivity (no leak).
- WebUI reachable via Traefik behind Authentik SSO.

## Notes

- gluetun creates `/dev/net/tun` itself (it has `NET_ADMIN`); no host device
  mapping. If the tunnel fails to start, ensure the host `tun` module is loadable.
- The compose `media` network has a fixed subnet (`172.28.0.0/16`) so it can be
  whitelisted in gluetun's firewall (`FIREWALL_OUTBOUND_SUBNETS`) — that is what
  keeps the WebUI reachable while everything else is forced through the VPN.
