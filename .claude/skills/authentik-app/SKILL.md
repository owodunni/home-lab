---
name: authentik-app
description: Guide for adding new applications to Authentik SSO in this home lab. Use when wiring up a new service to Authentik OAuth2/OIDC, creating providers/applications, or debugging SSO failures.
---

# Adding Applications to Authentik

## Overview

Each service needs two things in Authentik: a **Provider** (the OAuth2/OIDC config) and an **Application** (the entry point that links to the provider). The application slug determines the discovery URL.

## Step 1: Create the Provider

**Admin UI → Providers → Create → OAuth2/OpenID Provider**

| Field | Value |
|---|---|
| Name | `<Service Name>` |
| Authorization flow | `default-provider-authorization-implicit-consent` (home lab — no reason for explicit consent) |
| Client type | `Confidential` |
| Redirect URI | `https://<service>.jardoole.xyz<service-specific-callback-path>` |
| Signing Key | `authentik Self-signed Certificate` |

Save and **copy the Client ID and Client Secret** — you need these for the service config.

## Step 2: Create the Application

**Admin UI → Applications → Create**

| Field | Value |
|---|---|
| Name | `<Service Name>` |
| Slug | `<service>` (e.g. `grafana`) — this sets the discovery URL path |
| Provider | select the provider from Step 1 |

## Step 3: Configure the Service

Add the OAuth block to the service's `group_vars/<service>/main.yml` and store secrets in `group_vars/<service>/vault.yml` via `/vault`.

### Correct Authentik endpoint URLs (2025.6.x)

```
Auth URL:     https://auth.jardoole.xyz/application/o/authorize/
Token URL:    https://auth.jardoole.xyz/application/o/token/
Userinfo URL: https://auth.jardoole.xyz/application/o/userinfo/
```

Verify against the discovery document at:
```
https://auth.jardoole.xyz/application/o/<slug>/.well-known/openid-configuration
```

## Common Pitfalls

### 1. Wrong authorize/token URLs → 404

**The per-application slug does NOT appear in the authorize or token URL paths.**

In Authentik 2025.6.x the slug only appears in the discovery and end-session URLs:
- ✅ `https://auth.jardoole.xyz/application/o/authorize/`
- ❌ `https://auth.jardoole.xyz/application/o/grafana/authorize/`

Always confirm the correct URL from the discovery endpoint before configuring a service.

### 2. Missing Signing Key → 404 on authorize

If the provider has no Signing Key set, Authentik does not register the OIDC endpoints and returns 404. Always set **Signing Key → `authentik Self-signed Certificate`**.

### 3. Missing Authorization Flow → 404

The provider must have an **Authorization flow** assigned. Without it the authorize endpoint returns 404 even though the application and provider exist.

### 4. Redirect URI mismatch → invalid_client

The redirect URI in the provider must match exactly what the service sends — including trailing slashes and scheme. Check the service docs for the exact callback path.

### 5. Wrong Client ID → no matching provider

The client ID in the service config must match what Authentik generated. Double-check — they look similar but are not guessable.

## Vault Variables

Add to `group_vars/<service>/vault.yml`:

```yaml
vault_<service>_oauth_client_id: "<from Authentik UI>"
vault_<service>_oauth_client_secret: "<from Authentik UI>"
```

Reference in `main.yml` as `{{ vault_<service>_oauth_client_id }}` etc.

## Grafana Reference Implementation

See `group_vars/monitoring/main.yml` → `grafana_ini.auth.generic_oauth` for a working example.
