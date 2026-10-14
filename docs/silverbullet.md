# SilverBullet wiki (wiki.jardoole.xyz)

SilverBullet in **multi-space mode** on **valen**, behind the co-located Traefik.
Markdown wiki with account-based access and **Authentik OIDC SSO**.

- Playbook: `playbooks/silverbullet.yml` · Role: `roles/silverbullet` ·
  Config: `group_vars/silverbullet/` · Host: `[silverbullet]` (valen)
- Data folder on the host: `/opt/silverbullet/data` (mounted at `/data`) — holds
  the spaces **and** the server state (`users.json`, `authentication.json`).

## Why part of this is manual

Upstream exposes **no environment variable and no config file** for accounts,
spaces, the primary URL, or the OIDC provider — it is all configured in
SilverBullet's web Dashboard and persisted under the data folder; the very first
boot is an interactive setup wizard. So Ansible deploys the container, Traefik
route, backup, and monitoring wiring, and the steps below are a one-time
operator runbook. (Authentik provider creation is manual for every service in
this repo — there is no provider automation.)

Because the OIDC client secret lands in `authentication.json`, it is deliberately
**not** in `vault.yml`. It is protected by the data folder and carried by the
encrypted restic backup — restore the data folder and SSO comes back with it.

## Deploy

```bash
make app service=silverbullet   # container, Traefik route, Garage bucket + key
make app service=adguard        # publish the wiki.jardoole.xyz rewrite (see below)
```

Both are idempotent. The AdGuard redeploy is **mandatory, not optional**:
`group_vars/adguard/main.yml` already maps `wiki.jardoole.xyz` ->
`valen.jardoole.xyz`, but AdGuard serves a generated config
(`roles/adguard/templates/AdGuardHome.yaml.j2`), so the entry only takes effect
once AdGuard is redeployed. Until then LAN/VPN clients resolve the **public**
Cloudflare record for `wiki.jardoole.xyz` and hairpin out of the LAN — the wiki
still loads, over the wrong path, which is why this is easy to miss.

No Cloudflare or UniFi change is needed: the port is published on loopback only
and reached through the existing Traefik 443, never exposed publicly.

## 1. Confirm DNS resolves on the LAN

From a client that uses AdGuard (every LAN/VPN client does):

```bash
dig +short wiki.jardoole.xyz      # expect valen's LAN IP, never a Cloudflare one
```

A Cloudflare answer means AdGuard still has the old generated config — re-run
`make app service=adguard`. Do not continue until it answers with valen's IP:
setting the wiki up over the wrong host is what binds a space to a broken
address (see step 2).

## 2. First-run setup

> **Complete this over `https://wiki.jardoole.xyz`, never `http://<ip>:8005`.**
> Every space has a public address built from a *hostname + path*, and the wizard
> defaults it to the origin you are using. Setting it up over an IP:port binds the
> space to that address and it will not resolve behind Traefik.

1. Open <https://wiki.jardoole.xyz> — an unconfigured server redirects to `/.setup/`.
2. **Account creation** — create the first administrator (local username +
   password). Keep this account: it is the recovery path if SSO breaks.
3. **Space creation** — name it, accept the default folder (inside the data
   folder, i.e. `/data/spaces/<name>`), and bind it to the primary host at `/`.
4. Sign in, then **Admin → Server → Primary URL** = `https://wiki.jardoole.xyz`
   and save. SilverBullet derives the OIDC login origin from this value, so SSO
   cannot work until it is set.

## 3. Authentik: create the provider and application

Admin interface (<https://auth.jardoole.xyz>) → **Applications → Providers →
Create → OAuth2/OpenID Provider**:

| Field | Value |
| --- | --- |
| Name | `silverbullet` |
| Client type | `Confidential` |
| Client ID | `silverbullet` — Authentik pre-fills a random value; **replace it** |
| Redirect URIs (Strict) | `https://wiki.jardoole.xyz/.auth/central/oidc/callback` |
| Scopes | `openid`, `profile`, and the custom `email` mapping from below |
| Signing key | the default self-signed certificate is fine |

The callback is **central**: one URI for the whole server, spaces do not each
need their own. No PKCE toggle exists to flip — authentik supports PKCE
natively, and SilverBullet requests Authorization Code with PKCE.

### ⚠️ The `email_verified` step (required — SSO fails silently without it)

Since Authentik 2025.10 the default `email` scope mapping returns
`email_verified: False`, because an email address alone does not prove the user
controls it. **SilverBullet refuses any identity whose email is not verified**,
so on this lab's Authentik (2026.5.6) the stock provider will look correct and
still be rejected at the "test sign-in" step.

Create a custom mapping — **Customization → Property Mappings → New → Scope
Mapping**:

- Name: `oidc-email-verified`
- Scope name: `email`
- Expression:

  ```python
  return {
      "email": request.user.email,
      "email_verified": True,
  }
  ```

Then open the `silverbullet` provider and, under **Scopes**, **remove** the
default `email` mapping and add `oidc-email-verified` — never assign both.

Asserting `True` is acceptable here for the same reason Cornerstone's JIT
provisioning is: Authentik is the closed household IdP with no self-registration,
and every address is set by the administrator, so the population that can reach
this claim is exactly the intended one. If you would rather verify for real, use
Authentik's email stage instead — see
<https://docs.goauthentik.io/add-secure-apps/providers/oauth2/verify-email-address/>
(Option 2) and point the provider's `email` scope at it.

Then **Applications → Create**: name `SilverBullet`, **slug `silverbullet`**
(the slug determines the issuer URL:
`https://auth.jardoole.xyz/application/o/silverbullet/`), provider = the one
above. Optionally bind a policy restricting it to the household group.

## 4. SilverBullet: enable SSO

**Admin → Authentication → OpenID Connect**:

- Issuer URL: `https://auth.jardoole.xyz/application/o/silverbullet/`
- Client ID: `silverbullet`
- Client secret: from the Authentik provider

The wizard displays the callback URL it expects — confirm it reads
`https://wiki.jardoole.xyz/.auth/central/oidc/callback` before registering
anything. Then save, **test sign-in** (finish the provider sign-in in the test
window), review the returned identity, and **enable SSO**. A changed draft
requires another successful test before it can be activated; the test neither
creates an account nor replaces the administrator session.

The server must reach the issuer's discovery, token, and JWKS endpoints — same
LAN here, so nothing to do. A private CA could be supplied via `SB_OIDC_CA_FILE`
(not needed).

## 5. Users and space access

**Users → Add user → SSO**, type the expected email, review the suggested
username, and assign the spaces they need (`write` to contribute, `read` to
browse).

- **No auto-enrolment.** An unknown SSO user is refused; provision them here
  first. First sign-in binds the account to the provider's issuer + subject, so a
  later provider email change cannot silently move the account to someone else.
- Admins have `write` on every space.
- SilverBullet refuses to delete, demote, or disable the last enabled
  administrator, regardless of login method. Keep the local admin enabled (or at
  least keep an SSO admin) so you are never locked out.

## Backups

One restic snapshot of the **whole data folder** (spaces + `users.json` +
`authentication.json`) → Garage `silverbullet-backup` at 05:00, mirrored offsite
by the backup layer, freshness-alerted by `BackupLocalStale`.

```bash
make verify-backups SERVICE=silverbullet     # fresh? + repo integrity + restore points
make drill SERVICE=silverbullet              # non-destructive restore drill
make restore-backups SERVICE=silverbullet    # DESTRUCTIVE, typed confirm
```

There is only one restore point name: `data` (see the manifest in
`group_vars/silverbullet/main.yml`).

## Upgrading

Bump `silverbullet_image` in `group_vars/silverbullet/main.yml`, then
`make app service=silverbullet`. Release notes:
<https://github.com/silverbulletmd/silverbullet/releases>. After an upgrade the
browser client may need **two** reloads to pick up the new version.

## Notes and gotchas

- **Runtime API / extra packages.** The pinned image is the *default* variant,
  which bundles Chromium, so the Runtime API works. Drop
  `CONTAINER_BOOT.md` into the data folder to run a bash script at container boot
  (e.g. `apk add` extra packages). Switching the image tag to `-slim` removes
  Chromium and makes `/.runtime/*` return 503.
- **`307 → /.setup/`** on every path means the server is still unconfigured. This
  is also why the blackbox probe is green between deploy and setup: 307 is an
  accepted probe status, so no false alarm.
- **SSO login rejected after a successful provider test** → almost always the
  `email_verified` mapping above.
- **Space unreachable behind Traefik** → the space is bound to the wrong host.
  Fix **Admin → Server → Primary URL** and the space's public address
  (**Space settings → General**); both must be `wiki.jardoole.xyz`.
- **OIDC config is not in git** (by upstream design). `authentication.json` and
  `users.json` are the source of truth — hence the backup above.
- `SB_METRICS_PORT` exposes basic Prometheus metrics but is deliberately unused
  (it would need a published port + firewall rule + scrape job).
- Front door: Traefik router `silverbullet` → `127.0.0.1:8005`, **no
  forward-auth middleware** (native OIDC; forward-auth would break the WebSocket
  sync and the bearer-token HTTP API). Blackbox registry entry is `kind: app`.
