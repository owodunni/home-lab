# Vaultwarden (password manager)

Self-hosted, Bitwarden-compatible password manager. Compute, Postgres, and data
all run on a Pi (**pi-cm5-2**, co-located with Nextcloud), TLS is terminated by
the co-located Traefik, the **Postgres DB and the data dir are both backed up
offsite to Garage** (beelink, at the barn), and login is **SSO via Authentik**
(native OIDC) with a master password still protecting the vault.

- Playbook: `playbooks/vaultwarden.yml` (imported by the `applications` layer)
- Role: `roles/vaultwarden/`
- Config: `group_vars/vaultwarden/{main,vault}.yml`
- Inventory group: `[vaultwarden]` → `pi-cm5-2`
- URL: `https://vaultwarden.jardoole.xyz`

## Architecture

| Concern | Where |
|---|---|
| App (Vaultwarden) + Postgres | `pi-cm5-2`, one compose stack at `/opt/vaultwarden` |
| Vault data (`rsa_key*`, attachments, sends, `config.json`, icons) | local host dir `/opt/vaultwarden/data`, bind-mounted at `/data` |
| Postgres data | local Docker volume `vaultwarden-db` |
| DB backup | `pg-dump` → `db-backup` (restic) → Garage `vaultwarden-backup` |
| Data-dir backup | `data-backup` (restic) → Garage `vaultwarden-data-backup` |
| Login | Authentik OIDC (`SSO_ENABLED`) + master password |

### Why Postgres (not Vaultwarden's default SQLite)

So the database reuses the platform's existing **`pg_dump`→restic** backup engine
verbatim (the `postgres` backup type, same as Authentik/Nextcloud), giving a
guaranteed-consistent logical dump. Restic-ing a live `db.sqlite3` risks an
inconsistent snapshot. The DB lives in Postgres; everything else Vaultwarden
persists (RSA JWT signing keys, attachments, sends, `config.json`, icon cache)
lives in the local data dir and gets its own restic backup.

### Why native OIDC, not a Traefik forward-auth

Forward-auth would block the Bitwarden API and its clients (non-browser auth
flows), the same reason Nextcloud and Jellyfin use native auth in this lab.
Vaultwarden's built-in `SSO_ENABLED` integration keeps browser/extension/mobile
SSO via Authentik while the clients' own auth flows stay intact.

> **SSO ≠ vault encryption.** Authentik SSO authenticates the *user*; the vault
> itself stays end-to-end encrypted under a **master password** the user sets on
> first login. SSO gates access, the master password unlocks the vault. Both are
> needed on every client.

## First deploy

Secrets are generated and vaulted in `group_vars/vaultwarden/vault.yml` (the
deploy is otherwise unattended). Three things need a human first:

1. **DNS** — `vaultwarden.jardoole.xyz` must resolve to `pi-cm5-2` (the wildcard
   `*.jardoole.xyz` cert is handled by the ingress layer).

2. **Authentik provider** — create it in the Authentik UI (see next section). Its
   client secret must equal `vault_vaultwarden_oidc_client_secret`.

3. **First-user bootstrap** — see "Enrolling the first user" below.

Then deploy:

```bash
make app service=vaultwarden      # runs playbooks/vaultwarden.yml
```

## SSO — Authentik setup (manual, UI)

Use the `authentik-app` skill for the click-path. Create an **OAuth2/OpenID
Provider** + **Application**:

- **Application slug**: `vaultwarden` (the authority in
  `group_vars/vaultwarden/main.yml` is `…/application/o/vaultwarden/`).
- **Client type**: Confidential.
- **Client ID**: `vaultwarden` (`vaultwarden_sso_client_id`).
- **Client secret**: set it to `vault_vaultwarden_oidc_client_secret` (keep it
  alphanumeric — it rides a docker-compose `${...}` reference).
- **Redirect URI**: `https://vaultwarden.jardoole.xyz/identity/connect/oidc-signin`
- **Scopes**: `openid`, `email`, `profile`, **`offline_access`** (the last is
  required so Vaultwarden gets refresh tokens).
- **Signing key**: the Authentik default (RS256); **encryption key empty**.
- **Application → Bindings**: bind an access group (e.g. `vaultwarden-users`) so
  only those users can authenticate. Users in no bound group are denied at
  Authentik before reaching Vaultwarden.

### Making the `email_verified` claim true (required, or SSO is rejected)

**Symptom**: SSO redirects through Authentik and back, but Vaultwarden refuses the
login (logs show an unverified-email error).

**Root cause**: Authentik sets the OIDC `email_verified` claim to `False` by
default — it has no built-in per-user "verified" flag and so cannot assert it.
Vaultwarden, with its safe default `SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION=false`,
rejects any login whose `email_verified` is not `true`. Note that **SMTP and a
real email-verification flow do *not* flip this claim** — the default `email`
scope mapping hardcodes `False` regardless of whether the user verified anything.

**Fix** (Authentik UI → **Customization → Property Mappings**): edit the default
**OpenID `email`** scope mapping (or add a scope mapping bound to the Vaultwarden
provider) so it returns `email_verified: True`:

```python
return {
    "email": request.user.email,
    "email_verified": True,
}
```

This is Authentik's documented workaround and is safe **here** because this lab is
closed: users are admin-provisioned and gated by the Vaultwarden application
binding (above), so there is no open registration where an unverified address
could slip in. Do **not** also set Vaultwarden's
`SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION=true` — combined with the
`SSO_SIGNUPS_MATCH_EMAIL=true` this role sets, that would open an
account-takeover vector. Fixing the claim at Authentik is the correct layer.

> If you ever want a *real* per-user signal instead of an always-true constant,
> set the mapping to
> `request.user.attributes.get("email_verified", False)` and manage an
> `email_verified` user attribute (manually, or via an expression policy after an
> email-verification stage). More moving parts; unnecessary for this lab.

### Enrolling the first user

`SIGNUPS_ALLOWED` is `false`, so a brand-new SSO user can't create an account.
To enrol yourself the first time:

1. Set `vaultwarden_signups_allowed: true` in `group_vars/vaultwarden/main.yml`
   and run `make app service=vaultwarden`.
2. Log in once via SSO (see clients below) — this creates your account and you
   set your **master password**.
3. Set `vaultwarden_signups_allowed: false` again and re-run the playbook.

Access is gated at Authentik by the application binding throughout, so the brief
window is low-risk. Thereafter `SSO_SIGNUPS_MATCH_EMAIL=true` links any future
SSO login to the existing account with the same email.

> **Admin panel (`/admin`) is disabled** by default (no `ADMIN_TOKEN` set) — the
> most secure default, and it avoids the argon2 `$`-escaping pitfall in the
> compose `.env`. To enable it, generate a hash with
> `docker exec vaultwarden /vaultwarden hash`, vault it as
> `vault_vaultwarden_admin_token`, and wire `ADMIN_TOKEN` into the role (escape
> `$` as `$$` in the `.env`).

## Client setup

All official **Bitwarden** clients work against Vaultwarden — point each at the
self-hosted server, then log in with SSO. The master password unlocks the vault.

### Web vault
1. Visit `https://vaultwarden.jardoole.xyz`.
2. Click **Enterprise single sign-on**, enter any SSO identifier (Vaultwarden
   ignores the value), **Continue**.
3. You're redirected to Authentik → authenticate → back to Vaultwarden.
4. Set (first time) or enter your **master password** to unlock the vault.

### Browser extension (Chrome / Firefox / Edge)
1. Install the official **Bitwarden** extension.
2. On the login screen, **before** logging in, open the **Settings** (gear / cog)
   at the top-left.
3. Under **Self-hosted environment**, set **Server URL** to
   `https://vaultwarden.jardoole.xyz` → **Save**.
4. Back on login, choose **Enterprise single sign-on** → enter any SSO identifier
   → authenticate at Authentik → enter master password.

### Desktop app (Windows / macOS / Linux)
1. Install the official **Bitwarden** desktop app.
2. On the login screen, set the region dropdown to **Self-hosted** and enter
   **Server URL** `https://vaultwarden.jardoole.xyz` → Save.
3. **Log in with SSO** → authenticate at Authentik → master password.

### Mobile (iOS / Android)
1. Install the official **Bitwarden** app.
2. On the first login screen, tap the **Region** selector → **Self-hosted**, and
   set **Server URL** to `https://vaultwarden.jardoole.xyz`.
3. **Log in with SSO** → authenticate at Authentik → master password.
4. Enable biometric unlock in settings for convenience.

### CLI (`bw`)
```bash
bw config server https://vaultwarden.jardoole.xyz
bw login --sso            # opens a browser for the Authentik flow
bw unlock                 # prompts for the master password
```

## Backups

Both backups are restic snapshots to Garage (offsite, over WireGuard) with a
grandfather-father-son retention policy, and both are first-class in the unified
tooling:

```bash
make verify-backups  SERVICE=vaultwarden   # exist + fresh? + list every restore point
make restore-backups SERVICE=vaultwarden   # DESTRUCTIVE: restore latest of each (typed confirm)
```

| Backup | Engine | Bucket | Schedule |
|---|---|---|---|
| `postgres` | pg_dump → restic | `vaultwarden-backup` (`/restic` subpath) | `0 2 * * *` |
| `data` | restic of the data dir | `vaultwarden-data-backup` | `0 4 * * *` |

**Restoring an older snapshot** — pass `TARGETS` with short-IDs from
`make verify-backups`:

```bash
make restore-backups SERVICE=vaultwarden TARGETS='postgres=ab12cd34,data=ef56ab78'
```

> The `rsa_key*` files in the data dir sign the JWT session tokens. They are
> covered by the `data` backup; restoring them keeps existing client sessions
> valid. The Postgres DB holds the vaults, users, and org data.

## Maintenance

- **Upgrades**: bump `vaultwarden_image` in `group_vars/vaultwarden/main.yml` and
  re-run `make app service=vaultwarden`. Back up DB **and** data first
  (`make verify-backups` to confirm fresh snapshots).
- **Rotating secrets**: edit `group_vars/vaultwarden/vault.yml`
  (`uv run ansible-vault edit …`) and re-run the playbook. For the OIDC secret,
  update the Authentik provider to match. **Never** change
  `vault_vaultwarden_restic_password` without migrating the repos — it makes
  existing snapshots unrecoverable.
- **Logs**: `cd /opt/vaultwarden && docker compose logs -f vaultwarden`.
