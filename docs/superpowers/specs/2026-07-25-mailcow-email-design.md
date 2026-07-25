# Mailcow self-hosted email — design

Date: 2026-07-25
Status: approved

## Goal

Self-hosted **primary personal email** for the family (2–5 mailboxes, heavy
alias use) on `jardoole.xyz`, replacing Gmail as the daily driver. Existing
Gmail archives are migrated in. Runs on valen via mailcow-dockerized, with
Authentik SSO, vault-encrypted secrets, and the standard 3-2-1 backup path.
Only SMTP port 25 is exposed to the internet; everything else is LAN/WireGuard
only (phones use the existing VPN).

## Decisions made during brainstorming

| Question | Decision |
|---|---|
| Role | Primary personal email (family + heavy aliases) |
| Mail domain | `jardoole.xyz` (accepting the mild `.xyz` reputation penalty) |
| Host | valen (16 GB RAM, 199 GB free NVMe) — **Approach C**; the Pi co-location and NFS-vmail options were rejected (below) |
| Mail storage | Local NVMe Docker volumes on valen — never NFS, never Garage S3 |
| Inbound | Direct: public IP (dynamic, DDNS-maintained), UniFi port-forward 25 → valen (ISP confirmed non-CGNAT, ports open) |
| Outbound | **SMTP2GO smarthost relay** — direct send is impossible (dynamic IP, no PTR, see below); relay endpoint/credentials are plain group_vars + vault, so a different smarthost is a variable swap |
| Exposure | Port 25 only public; 465/587/993 + web UI are LAN/WG-only |
| SSO | mailcow native Generic-OIDC against Authentik (per vendor guide) |
| AV | ClamAV enabled (valen has the RAM) |

### Rejected alternatives

- **vmail on NFS from valen** (original idea): Dovecot over NFS is a
  documented source of index corruption and locking bugs; maildir's millions
  of small files are the worst case for NFS and SnapRAID; and it couples mail
  to a two-host failure domain (the 2026-07-20 valen outage would have taken
  Pi-hosted mail down with it anyway).
- **Garage S3 as primary mail store**: Dovecot's object-storage backend
  (obox) is Dovecot **Pro** only — not available in mailcow. Garage's role is
  backup target.
- **Co-locate on pi-cm5-2 with Nextcloud**: fits only with ClamAV disabled
  (8 GB RAM) and puts a growing Gmail-archive-sized mail store on eMMC.
  Rejected in favour of valen once migration volume was factored in.
- **Direct outbound send** (the original "try direct first" decision): the
  public IP is dynamic, so the ISP cannot assign a PTR record, and reverse
  DNS lives in the ISP's `in-addr.arpa` zone — not something DDNS or
  Cloudflare can fix. Without forward-confirmed reverse DNS (and with the
  IP block on Spamhaus PBL), Gmail/Outlook reject direct sends outright.
  Relay-only outbound is the design, not a fallback.
- **Cloudflare Email Service as the outbound relay** (considered since the
  domain is already on Cloudflare): rejected for a 5 MiB max message size
  (~3.5 MB of real attachments — far below the 25 MB family users expect),
  beta status, and an implicit-TLS-465-only endpoint that mailcow's
  relayhost config doesn't speak without extra Postfix configuration.
- **Cloudflare Email Routing for inbound**: onboarding it rewrites the
  domain's MX to Cloudflare and forwards to existing mailboxes — it would
  hijack inbound mail away from mailcow. It stays off.

## Architecture

### Placement & runtime

- New `[mailcow]` inventory group → valen. One-line move, per repo convention.
- `playbooks/mailcow.yml` in the **applications** layer + `roles/mailcow`.
- The role clones `mailcow/mailcow-dockerized` to `/opt/mailcow-dockerized`
  at a **pinned git tag** (`mailcow_version` in group_vars). Upgrades are a
  deliberate tag bump + re-run, replacing mailcow's `update.sh` self-update
  model — same spirit as the repo's image-pinning convention. The role must
  remain idempotent over an existing checkout.
- `mailcow.conf` is generated from a template in `roles/mailcow`; every value
  it consumes lives in `group_vars/mailcow/` (`main.yml` + `vault.yml`), per
  the no-role-defaults rule.
- Mailcow manages its own compose project (its own networks/volumes); we do
  not merge it into any existing compose file. Watch for Docker subnet
  collisions with existing networks (mailcow defaults to `172.22.1.0/24`).
- All data (vmail, MariaDB, Redis, Rspamd) in mailcow's Docker volumes on the
  NVMe root — deliberately **not** on the MergerFS pool (spin-down, SnapRAID
  small-file behaviour, pool is for media).

### Mail flow & DNS

Records in Cloudflare (mail-related records **DNS-only / grey-cloud** —
Cloudflare cannot proxy SMTP):

| Record | Value |
|---|---|
| A `mail.jardoole.xyz` | home public IP (DDNS-maintained if dynamic) |
| MX `jardoole.xyz` | `mail.jardoole.xyz` |
| TXT SPF | `v=spf1 mx include:spf.smtp2go.com -all` |
| TXT DKIM | two signatures: SMTP2GO's (CNAME records from their sender-domain verification) and mailcow's own key, pasted into Cloudflare |
| TXT DMARC | `v=DMARC1; p=quarantine; rua=mailto:alex.o.poole@gmail.com` — reports go to Gmail during the transition; start at `quarantine`, move to `reject` once mail flow is proven |
| CNAME `autoconfig` / `autodiscover` | `mail.jardoole.xyz` |

- UniFi split-horizon: `mail.jardoole.xyz` A-override → valen's LAN IP, so
  LAN and VPN clients reach IMAP/submission directly. Same AAAA caveat as
  every other service (clients must prefer IPv4 or the public record wins).
- **Outbound**: all mail relays through **SMTP2GO** (STARTTLS submission,
  SMTP-user credentials in `group_vars/mailcow/vault.yml`), configured as
  mailcow's relayhost and assigned to the domain. Mail leaves from SMTP2GO's
  IPs with their PTR/reputation — required because the home IP is dynamic
  (no PTR possible, block is on Spamhaus PBL). Free tier is 1,000
  emails/month; the endpoint/credentials are plain variables, so swapping
  providers later is a config change, not a redesign.
- **Bootstrap order (receive first, then send):** SMTP2GO signup itself
  requires a working mailbox on your own domain, so the rollout is
  two-stage: deploy mailcow **inbound-only** (MX + port 25 live, relay
  unconfigured — outbound to external domains held back), verify receiving
  at an `@jardoole.xyz` address, then register SMTP2GO with that address
  and configure the relay to bring outbound live.
- **Operator prerequisites (user):**
  1. Confirm DDNS keeps the `mail.jardoole.xyz` A record current
     (before inbound go-live).
  2. After receiving works: create an **SMTP2GO** account (signing up with
     the new `@jardoole.xyz` mailbox), add `jardoole.xyz` as a verified
     sender domain, add their SPF include + DKIM CNAMEs to Cloudflare, and
     create an SMTP user for mailcow (credentials → vault).

### Exposure & firewall

Declared as `firewall_rules_mailcow` in `group_vars/mailcow/main.yml`
(default-deny ufw fleet; Docker-published ports via DOCKER-USER, see
`docs/port-inventory.md`):

| Port | Scope | Purpose |
|---|---|---|
| 25/tcp | **public** (UniFi forward → valen) | inbound MX |
| 465, 587/tcp | LAN + WireGuard only | mail-client submission |
| 993/tcp | LAN + WireGuard only | IMAPS |
| 443 (via Traefik) | LAN + WireGuard only (existing rules) | mailcow UI / SOGo webmail |

POP3 (110/995) and ManageSieve (4190) stay disabled/unpublished unless a
need appears. Mailcow's built-in netfilter (fail2ban-like) container stays
enabled for the exposed port.

### TLS

- Valen's Traefik keeps 80/443. It routes `mail.jardoole.xyz` → mailcow's
  nginx bound to loopback (`HTTP_BIND=127.0.0.1`, `HTTP_PORT` high port,
  `SKIP_LETS_ENCRYPT=y`).
- The wildcard cert is exported from Traefik's ACME store into
  `data/assets/ssl/` for Postfix/Dovecot TLS (the documented mailcow
  reverse-proxy recipe), with a renewal hook that re-exports and reloads
  postfix/dovecot/nginx. Implementation detail (cert-dumper vs. script) is
  decided at plan time.

### SSO (Authentik Generic-OIDC)

Follows the vendor guide saved at `mailcow-sso.md` + the repo `authentik-app`
skill:

- Authentik: custom `email` scope mapping (returns `email_verified`),
  `mailcow_template` scope mapping, OAuth2/OIDC provider + application,
  redirect URI `https://mail.jardoole.xyz`. Family users get
  `email_verified: true` and `mailcow_template: default` attributes.
- mailcow: Identity Provider = Generic-OIDC (authorize/token/userinfo
  endpoints, client ID/secret), **auto-create mailboxes on login** with the
  default template, so family members onboard by simply signing in.
- Native mail clients (phones) authenticate with per-device **app passwords**
  created in the mailcow UI — OIDC cannot carry IMAP/SMTP auth.
- Client ID/secret live in `group_vars/mailcow/vault.yml` (`vault_` prefix,
  ansible-vault encrypted), as does the mailcow admin password and DB/API
  secrets.
- SOGo/webmail login stays on the LAN/VPN-only UI; Authentik outage does not
  affect mail delivery, only interactive login.

### Backups (3-2-1)

Standard manifest-driven machinery in `group_vars/mailcow/main.yml`.
Implementation surfaced that mailcow needs **two** new backup engines, not
one — its data lives in Docker *named volumes*, unlike every existing
service's host bind-mounts:

- **MariaDB — new `mysqldump` engine**: a mariadb-client sidecar (image
  pinned to match mailcow's own `mysql-mailcow` tag) writes
  `mysqldump --single-transaction --all-databases` to a shared volume; a
  restic sidecar snapshots it. Verify/run/drill delegate to the shared
  restic handlers (like `postgres`); restore loads the plain-SQL dump via
  the `mysql` client; the drill validates structurally (mysqldump header +
  `-- Dump completed` footer — plain SQL has no `pg_restore --list`
  equivalent).
- **Volumes — new `restic_volumes` engine**: restic snapshots of the
  vmail/crypt/postfix/Redis/Rspamd/SOGo *named volumes*. The plain `restic`
  engine's restore does a host `cp -a` into `compose_dir/<path>`, which
  doesn't exist for a named volume — `restic_volumes` restores into the live
  volume via a throwaway `alpine` bridge container instead, addressed by the
  volume's real on-disk name (`<compose-project>_<volume>`, the manifest's
  `volume_prefix` field). Verify/run/drill delegate to the shared restic
  handlers unchanged. Raw MariaDB/ClamAV/TLS-policy volumes are deliberately
  excluded (crash-inconsistent live copy / freely re-downloadable).
- **Sidecar wiring**: mailcow owns its own compose project, so the sidecars
  are added via `docker-compose.override.yml` (auto-merged by Compose),
  and their secrets live in an Ansible-managed section of `mailcow.conf`
  itself — mailcow hard-requires `.env` to be a symlink to `mailcow.conf`,
  and Compose reads exactly one default env file per project.
- Targets local Garage on valen; beelink pulls the buckets offsite with the
  read-only key, as everywhere else. `make run-backups/verify-backups/drill
  SERVICE=mailcow` all work.
- Accepted trade: primary data **and** the local Garage copy share valen
  (same as the media stack); the offsite beelink mirror is the real
  disaster copy.
- Redis/Rspamd data is reconstructible spam-training state — included in the
  volume snapshot but not drill-critical. The crown jewels are vmail +
  MariaDB.

### Gmail migration

Mailcow **Sync Jobs** (built-in imapsync): per-mailbox pull from Gmail over
IMAP using a Google app password. Run from the mailcow UI after go-live;
documented as a runbook step in the role's docs, not automated. Cut-over
order: DNS/deliverability proven → sync archive → repoint senders/contacts →
Gmail forwards to the new address during the transition.

### Monitoring

- `mail.jardoole.xyz` added to the `monitoring_blackbox_services` registry
  (the pre-commit guard enforces this) — front-door liveness + cert expiry.
- Backup-freshness exporter picks up the new manifests automatically
  (`BackupLocalStale` / `BackupMirrorStale`).
- Out of scope but noted: valen still ships no container logs to Loki (known
  gap, tracked separately); SMTP-level blackbox probes (port 25 banner
  checks) are a possible follow-up, not in this spec.

## Risks accepted

- **Valen SPOF**: mail is down whenever valen is down (cf. the 55 h
  2026-07-20 outage). Mitigation: sending MTAs retry for days, so short
  outages delay mail rather than lose it; host-resilience layer now
  auto-reboots hangs.
- **Deliverability**: SMTP2GO's IP reputation carries outbound, but the
  `.xyz` TLD penalty remains, and the free tier caps at 1,000 emails/month
  (family volume fits; a runaway script or mass-mail would hit it). DMARC
  reports will surface problems early.
- **Relay dependency**: outbound mail now depends on a third party's
  availability and account standing; inbound is unaffected. Endpoint and
  credentials are variables, so a provider swap is quick.
- **Family UX**: reading mail off-LAN requires WireGuard on every family
  device; app-password setup per device.
- **Upgrade discipline**: pinned-tag model means security updates arrive
  only when we bump the tag — mailcow releases monthly; needs an operator
  habit (or a later automation) to review releases.

## Out of scope

- Fixing the split-horizon AAAA leak (pre-existing, tracked).
- Valen → Loki log shipping (pre-existing gap).
- SMTP blackbox probes, DANE/TLSA, MTA-STS (nice-to-haves, revisit after
  go-live).
- Automated Gmail migration.
