# Mailcow (self-hosted email)

Self-hosted primary personal email for the family (`jardoole.xyz`), replacing
Gmail. Runs on **valen** as its own docker-compose project (cloned from
upstream `mailcow/mailcow-dockerized`, pinned tag), behind the co-located
Traefik, with **Authentik SSO**, vault-encrypted secrets, and the standard
3-2-1 backup path. Only SMTP (`25/tcp`) is exposed to the internet; everything
else is LAN/WireGuard only.

Full design rationale: `docs/superpowers/specs/2026-07-25-mailcow-email-design.md`.
Vendor reference guides used while building this: `install-mailcow.md`,
`mailcow-sso.md` (repo root).

- Playbook: `playbooks/mailcow.yml` (imported by the `applications` layer)
- Role: `roles/mailcow/`
- Config: `group_vars/mailcow/{main,vault}.yml`
- Inventory group: `[mailcow]` -> `valen`
- URL: `https://mail.jardoole.xyz`

## Architecture

| Concern | Where |
|---|---|
| App (mailcow's own compose project) | `valen`, `/opt/mailcow-dockerized` (cloned, not authored here) |
| vmail, MariaDB, Redis, Rspamd | mailcow's own Docker named volumes, on the NVMe root — **not** the MergerFS pool |
| Web UI / SOGo webmail | loopback `127.0.0.1:8090`, proxied by Traefik at `mail.jardoole.xyz` (plus `autoconfig`/`autodiscover.jardoole.xyz` — mailcow's nginx serves those client-autoconfig endpoints on the same port, distinguished by Host header) |
| SMTP (inbound MX) | `25/tcp`, public (UniFi port-forward) |
| SMTPS / submission / IMAPS | `465` / `587` / `993`, LAN + WireGuard only |
| POP3 / POP3S / ManageSieve / plaintext IMAP | disabled (loopback-bound, never published) |
| TLS for Postfix/Dovecot | wildcard cert exported from Traefik's `acme.json` (mailcow's own ACME is disabled) |
| DB backup | `db-dump` (mysqldump) -> `db-backup` (restic) -> Garage `mailcow-backup` |
| Volumes backup | `volumes-backup` (restic) -> Garage `mailcow-volumes-backup` |
| Outbound relay | SMTP2GO (configured in the mailcow UI, **not** Ansible-managed — see "Two-stage rollout") |

### Why mailcow owns its own compose project

Every other service in this repo has an Ansible-authored `docker-compose.yml.j2`
— but those are 1–3 containers configured almost entirely through environment
variables, so authoring the compose file ourselves is cheap. mailcow-dockerized
is a different animal: ~19 tightly coupled services (Postfix, Dovecot, Rspamd,
nginx, MariaDB, Redis, SOGo, ClamAV, Unbound, watchdog, …) whose compose file
bind-mounts hundreds of upstream-maintained config files from the repo's
`data/conf/` tree by **relative path** (`./data/conf/postfix/`, …). The compose
file does not work standalone — it only functions inside the upstream git tree,
and upstream revises compose file, config tree, and image tags **in lockstep**
with every monthly release (their supported update path, `update.sh`, is
essentially a `git pull`). Templating the compose file would mean vendoring
all of that and hand-reconciling it against every upstream release.

So the role clones the repo at a pinned git tag and leaves it completely
untouched, templating only the two files upstream itself treats as the
operator's: `mailcow.conf` (what their `generate_config.sh` would have
written) and a `docker-compose.override.yml` (which `docker compose` merges
automatically, same directory, no `-f` flag needed) adding the backup
sidecars. A `mailcow_version` bump therefore never has to reconcile
Ansible-authored edits against upstream's compose file. See
`roles/mailcow/tasks/main.yml` and the override template's header comment.

### Why MariaDB isn't restic'd directly

Mailcow's `mysql-mailcow` data directory is crash-inconsistent if snapshotted
live — same reasoning as every Postgres-backed service in this repo. A
`mysqldump --all-databases --single-transaction` sidecar (`db-dump`) writes a
consistent logical dump to a shared volume on a schedule; a restic sidecar
(`db-backup`) snapshots *that* dump. This needed a new backup engine,
`mysqldump` (`roles/backup_{verify,run,restore,drill}/tasks/mysqldump.yml`),
mirroring the existing `postgres` engine's verify/run (both just delegate to
the shared `restic` handler) and restore (load the dump into the live DB —
here via `mysql`, not `pg_restore`).

### Why the volumes backup needed a second new engine

Unlike every other restic-backed service, mailcow's vmail/Rspamd/Redis/config
data lives in Docker **named volumes** (`vmail-vol-1`, `crypt-vol-1`, ...), not
host bind-mount directories under the compose dir. The named volumes are
inherited, not chosen: upstream's compose file declares them, and since that
file is deployed untouched (see above), its storage layout comes with it.
Rewriting ~10 volume definitions into bind mounts via the override file would
work mechanically, but upstream's permission bootstrapping, update path, and
docs all assume the named volumes — it would recreate exactly the per-release
reconciliation burden the clone-untouched approach exists to avoid. Teaching
the backup machinery one new engine was the cheaper, one-time cost. The existing `restic`
engine's restore handler does a host `cp -a {{ compose_dir }}/.restore/data/<path>
{{ compose_dir }}/<path>` — there is no such host directory for a named
volume. `restic_volumes` (a second new engine,
`roles/backup_{verify,run,restore,drill}/tasks/restic_volumes.yml`) is
identical to `restic` for verify/run/drill (all delegate straight through —
listing/checking/drilling a snapshot doesn't care what kind of path produced
it) and only differs in restore, which copies each restored path back into its
live named volume via a throwaway `alpine` container bridging the scratch
restore dir and the volume, instead of a host `cp`.

### Upstream's ufw and ACME-validation warnings (already accounted for)

mailcow's docs carry two loud warnings that look alarming for this deploy but
are both already designed around:

- **"Validation errors / SKIP_IP_CHECK / SKIP_HTTP_VERIFICATION"** — these
  only steer `acme-mailcow`'s Let's Encrypt HTTP validation, and this deploy
  sets `SKIP_LETS_ENCRYPT=y`: `acme-mailcow` never runs a validation at all.
  The cert is exported from Traefik's ACME store, which renews via **DNS-01**
  (Cloudflare) — no inbound HTTP challenge, no IP check, no NAT-reflection
  dependency, no ports 80/443 exposure. Both `SKIP_*` flags stay at upstream's
  `n` defaults purely to keep the `mailcow.conf` diff small (see the comment
  in `roles/mailcow/templates/mailcow.conf.j2`).

- **"Don't run mailcow behind ufw/firewalld — INPUT rules have no effect;
  move your ruleset to the DOCKER-USER chain"** — that is *exactly* what this
  lab's firewall already does, fleet-wide. `firewall_rules_mailcow` entries
  are `scope: docker`, which `roles/firewall` renders into the **DOCKER-USER**
  chain (persisted in `/etc/ufw/after.rules` via
  `docker-user-block-v4.j2`, so neither a Docker restart nor a ufw reload
  loses them). The chain only gates ingress arriving on the host's external
  interface: container-originated outbound leaves via `br-mailcow` and its
  replies return as ESTABLISHED, so mailcow's outbound DNS/SMTP is untouched.
  `netfilter-mailcow` (mailcow's fail2ban-alike) inserts its own ban-chain
  jump at the top of DOCKER-USER at runtime — ahead of our ACCEPT rules, so
  bans win, which is the right precedence — and re-asserts it itself if a
  ufw reload rebuilds the chain.

## Secrets to generate

Before the first run, create `group_vars/mailcow/vault.yml` (`uv run
ansible-vault create group_vars/mailcow/vault.yml`, see the `vault` skill) with
these 12 `vault_mailcow_*` vars. Formats below aren't arbitrary — several are
hard constraints from mailcow or Garage, not just "make it random":

| Variable | Format | Generate with | Used for |
|---|---|---|---|
| `vault_mailcow_dbpass` | 28 chars, `A-Za-z0-9` only (**no special chars** — mailcow's own convention, and it rides a docker-compose `${VAR}` reference so a stray `$` would break interpolation) | `openssl rand -base64 32 \| tr -dc 'A-Za-z0-9' \| head -c 28` | MariaDB app-user password (`DBPASS`) |
| `vault_mailcow_dbroot` | same: 28 chars, `A-Za-z0-9` only | same command | MariaDB root password (`DBROOT`) |
| `vault_mailcow_redispass` | same: 28 chars, `A-Za-z0-9` only | same command | Redis password (`REDISPASS`) |
| `vault_mailcow_sogo_url_encryption_key` | **exactly 16 chars**, `A-Za-z0-9` only — hard requirement, mailcow rejects anything else | `openssl rand -base64 32 \| tr -dc 'A-Za-z0-9' \| head -c 16` | SOGo URL encryption key |
| `vault_mailcow_api_key` | alphanumeric (mailcow allows `a-z A-Z 0-9 -` too, but plain alnum is simplest), ~32 chars | `openssl rand -hex 16` (32 hex chars) | Pre-seeds the admin API key (`API_KEY` in mailcow.conf) |
| `vault_mailcow_oidc_client_id` | alphanumeric, ~40 chars (matches Authentik's own default client-ID shape) | `openssl rand -hex 20` (40 hex chars) | Pasted into **both** the Authentik provider's Client ID field and mailcow's Identity Provider form (see "SSO" below) |
| `vault_mailcow_oidc_client_secret` | free-form, long; base64 is fine | `openssl rand -base64 48` | Pasted into both sides' Client Secret field, same as above |
| `vault_mailcow_restic_password` | 32 bytes, base64 — repo-wide convention for every restic repo password | `openssl rand -base64 32` | Encrypts **both** restic repos (DB + volumes) — losing it makes existing snapshots unrecoverable |
| `vault_mailcow_backup_s3_access_key` | Garage format: `GK` + 24 lowercase hex chars | `scripts/garage-keygen.sh vault_mailcow_backup_s3` (prints both halves as ready-to-paste YAML) | MariaDB-dump restic repo's Garage key (bucket `mailcow-backup`) |
| `vault_mailcow_backup_s3_secret_key` | Garage format: 64 lowercase hex chars | (same command as above) | pairs with the access key above |
| `vault_mailcow_volumes_backup_s3_access_key` | Garage format: `GK` + 24 lowercase hex chars | `scripts/garage-keygen.sh vault_mailcow_volumes_backup_s3` | Volumes restic repo's Garage key (bucket `mailcow-volumes-backup`) — **must be a separate key pair** from the DB one above, independent bucket/retention |
| `vault_mailcow_volumes_backup_s3_secret_key` | Garage format: 64 lowercase hex chars | (same command as above) | pairs with the access key above |

Don't hand-roll the Garage key pairs — `scripts/garage-keygen.sh` produces the
exact format Garage's import validates against (see the `garage-keys` skill).
Everything else above is a plain `openssl rand` recipe; the alphanumeric-only
constraints on the first four exist because those values get interpolated into
`mailcow.conf`/docker-compose `${VAR}` references, where a `$`, quote, or space
could break parsing.

## First deploy

Three things need a human before/around the first run:

1. **DNS** (Cloudflare, `jardoole.xyz`, all mail records DNS-only/grey-cloud —
   Cloudflare cannot proxy SMTP):

   | Record | Value |
   |---|---|
   | A `mail.jardoole.xyz` | home public IP (DDNS-maintained) |
   | MX `jardoole.xyz` | `mail.jardoole.xyz` |
   | TXT SPF | `v=spf1 mx include:spf.smtp2go.com -all` |
   | TXT DKIM | SMTP2GO's (from their sender-domain verification) **and** mailcow's own key (Configuration -> ARC/DKIM keys, once mailcow is up) |
   | TXT DMARC | `v=DMARC1; p=quarantine; rua=mailto:alex.o.poole@gmail.com` (start at `quarantine`, move to `reject` once mail flow is proven) |
   | CNAME `autoconfig` / `autodiscover` | `mail.jardoole.xyz` |

2. **UniFi**:
   - Port-forward `25/tcp` -> valen's LAN IP (public inbound MX).
   - Confirm DDNS keeps the public `mail.jardoole.xyz` A record current
     *before* inbound go-live.

   (No split-horizon step here: LAN/VPN clients resolve `mail.jardoole.xyz` —
   and `autoconfig`/`autodiscover` — to valen via the AdGuard rewrites in
   `group_vars/adguard/main.yml`, the same mechanism as every other
   `*.jardoole.xyz` service — redeploy AdGuard (`make app service=adguard`)
   if it hasn't picked the entries up yet.)

3. **Garage buckets/keys** — provisioned automatically by the first play in
   `playbooks/mailcow.yml`, as long as the vault vars above are set first.

Then deploy:

```bash
make app service=mailcow      # runs playbooks/mailcow.yml
```

### First login

1. Visit `https://mail.jardoole.xyz/admin`, log in with `admin` / `moohoo`.
2. **Change the admin password immediately** and record it in your password
   manager — it lives only in mailcow's own DB (not `mailcow.conf`), so
   nothing in Ansible or the vault manages it.
3. Confirm **System -> Configuration -> Access -> API** shows the key matching
   `vault_mailcow_api_key` (pre-seeded via `mailcow.conf`'s `API_KEY`) — rotate
   it here if you ever need to.

## Two-stage rollout: receive first, then send

SMTP2GO signup itself requires a working mailbox on your **own** domain, so
this is a deliberate two-stage rollout, not a single deploy:

**Stage 1 — inbound only.** After first deploy, MX + port 25 are live but
outbound to external domains is NOT yet relayed anywhere (no relayhost is
configured). Create a mailbox (Mail Setup -> Mailboxes -> Add mailbox) and
confirm you can receive mail sent to `you@jardoole.xyz` from an external
account.

**Stage 2 — configure the SMTP2GO relay** (manual, UI — not automated):

1. Sign up for SMTP2GO **using the new `@jardoole.xyz` mailbox** you just
   proved works.
2. Add `jardoole.xyz` as a verified sender domain in SMTP2GO; add their SPF
   include and DKIM CNAME records to Cloudflare (see the DNS table above).
3. Create an SMTP user for mailcow in SMTP2GO.
4. In mailcow: **Admin -> Configuration -> Routing -> Relayhost**, add
   SMTP2GO's host/port and the SMTP user's credentials, then assign it to
   `jardoole.xyz` under the domain's relay settings.
5. Send a test message to an external address (e.g. Gmail) and confirm it
   arrives without landing in spam.

Direct outbound send was rejected in the design (dynamic IP, no PTR possible,
IP block on Spamhaus PBL — see the design spec's "Rejected alternatives").
SMTP2GO's free tier is 1,000 emails/month; the endpoint/credentials are plain
vault vars, so switching providers later is a config change, not a redesign.

## SSO — Authentik Generic-OIDC setup (manual, UI)

Condensed from `mailcow-sso.md` (vendor guide) + the repo's `authentik-app`
skill. `vault_mailcow_oidc_client_id` / `vault_mailcow_oidc_client_secret` are
pre-generated in the vault specifically so you can **set** them on both sides
below instead of copy-pasting an Authentik-generated value back into vault.

### Authentik side

1. **Customization -> Property Mappings -> New** -> Scope Mapping:
   - Name/scope `email`, expression per Authentik's
     [email scope verification](https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/#email-scope-verification)
     docs (returns `email_verified`).
   - A second Scope Mapping, name/scope `mailcow_template`:
     ```python
     return {
         "mailcow_template": request.user.attributes.get("mailcow_template", "default"),
     }
     ```
2. **Directory -> Users**, for each family member who should get mailcow SSO,
   add attributes:
   ```yaml
   email_verified: true
   mailcow_template: default
   ```
   (The user's Authentik email must match their mailcow mailbox address for
   *existing* mailboxes; auto-created mailboxes just need the domain to
   already exist in mailcow.)
3. **Applications -> New Application**:
   - Provider type: OAuth2/OpenID Connect.
   - **Client ID**: set to `vault_mailcow_oidc_client_id`.
   - **Client Secret**: set to `vault_mailcow_oidc_client_secret`.
   - Redirect URI: `https://mail.jardoole.xyz` (type `Strict`, `Authorization`).
   - Signing key: `authentik Self-signed Certificate`.
   - Advanced protocol settings: remove the default OpenID `email` scope
     mapping from Selected Scopes; add the custom `email` and
     `mailcow_template` mappings from step 1 instead.
   - Bind an access group (e.g. `mailcow-users`) so only family accounts can
     authenticate.

### mailcow side

**System -> Configuration -> Access -> Identity Provider**, select
`Generic-OIDC`:

- Authorization endpoint: `https://auth.jardoole.xyz/application/o/authorize/`
- Token endpoint: `https://auth.jardoole.xyz/application/o/token/`
- Userinfo endpoint: `https://auth.jardoole.xyz/application/o/userinfo/`
- Client ID / Secret: `vault_mailcow_oidc_client_id` / `vault_mailcow_oidc_client_secret`
- Redirect URL: `https://mail.jardoole.xyz`
- Attribute Mapping: Attribute `default` -> Template = whichever mailbox
  template new users should get.
- Enable **Auto-create users on login** so family members onboard by simply
  signing in (mailbox created from the default template on first SSO login).

For any mailbox that already exists, edit it under **Mail Setup -> Mailboxes**
and set **Identity Provider** to `Generic-OIDC` so it can also log in via SSO.

> **Native mail clients (phones, desktop MUAs) cannot use OIDC** — IMAP/SMTP
> auth has no browser to redirect. Create a per-device **app password**
> (mailcow UI -> Mailbox Settings -> App Passwords) for each client instead.
> SOGo/webmail stays LAN/VPN-only regardless of SSO; an Authentik outage
> blocks interactive login but never mail delivery.

## Gmail migration

Mailcow's built-in **Sync Jobs** (imapsync) pull each mailbox from Gmail over
IMAP using a Google app password. Per mailbox: **Mail Setup -> Mailboxes ->
(mailbox) -> Sync Jobs -> Add sync job**, host `imap.gmail.com`, port 993,
your Gmail address + app password. Not automated — run from the UI after
go-live. Suggested cut-over order:

1. Prove DNS/deliverability (stage 1 + stage 2 above).
2. Run the sync job per mailbox; let it complete (large archives take a while).
3. Repoint senders/contacts to the new `@jardoole.xyz` address.
4. Set up Gmail-side forwarding to the new address during the transition
   window, then retire it once confident.

## Backups

Both backups are restic snapshots to Garage (local on valen, mirrored offsite
to beelink by the `backup` layer) with the same grandfather-father-son
retention every service in this lab uses:

```bash
make verify-backups  SERVICE=mailcow   # exist + fresh? + list every restore point
make drill           SERVICE=mailcow   # non-destructive: prove both backups restore
make restore-backups SERVICE=mailcow   # DESTRUCTIVE: restore latest of each (typed confirm)
```

| Backup | Engine | Bucket | Schedule |
|---|---|---|---|
| `mariadb` | mysqldump -> restic (new `mysqldump` engine) | `mailcow-backup` (`/restic` subpath) | `0 4 * * *` |
| `volumes` | restic of named volumes (new `restic_volumes` engine) | `mailcow-volumes-backup` | `0 5 * * *` |

**Restoring an older snapshot** — pass `TARGETS` with short-IDs from
`make verify-backups`:

```bash
make restore-backups SERVICE=mailcow TARGETS='mariadb=ab12cd34,volumes=ef56ab78'
```

> Redis/Rspamd data (bayes/spam-training state) is included in the `volumes`
> backup but is reconstructible — not drill-critical. The crown jewels are
> `vmail-vol-1` (actual mail) and the `mariadb` backup (accounts, aliases,
> domains, Sieve filters, SOGo preferences metadata).

## Maintenance

- **Upgrades**: bump `mailcow_version` in `group_vars/mailcow/main.yml` to a
  newer dated tag (https://github.com/mailcow/mailcow-dockerized/releases),
  re-run `make app service=mailcow`. This replaces mailcow's own `update.sh`
  self-update — review each release's notes for breaking changes first, and
  confirm fresh backups (`make verify-backups SERVICE=mailcow`) beforehand.
- **TLS**: the wildcard cert is re-exported from Traefik's `acme.json`
  automatically (`mailcow-cert-export.timer`, hourly) — no action needed as
  long as Traefik itself keeps renewing.
- **Rotating secrets**: edit `group_vars/mailcow/vault.yml`
  (`uv run ansible-vault edit …`) and re-run the playbook. **Never** change
  `vault_mailcow_restic_password` without migrating the repos — it makes
  existing snapshots unrecoverable.
- **Logs**: `cd /opt/mailcow-dockerized && docker compose logs -f <service>`
  (service names end in `-mailcow`, e.g. `postfix-mailcow`, `dovecot-mailcow`).
- **Docker subnet**: `mailcow_docker_ipv4_network` (`172.30.1`) was chosen to
  avoid a real collision found on valen — see the comment in
  `group_vars/mailcow/main.yml` for the `docker network inspect` evidence.
  Re-check before ever changing it.
