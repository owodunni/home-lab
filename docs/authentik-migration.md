# Authentik SSO Migration Guide

Step-by-step guide to enable Authentik authentication for home lab services.

## Overview

This guide covers migrating services to use Authentik for centralized authentication.

### Groups Strategy (Simplified Tiered System)

Instead of creating app-specific groups (Grafana Admins, Sonarr Admins, etc.),
use a tiered system:

| Authentik Group | Purpose | App Mappings |
|-----------------|---------|--------------|
| `Admins` | Full admin access everywhere | Grafana Admin, full API access |
| `Users` | Standard authenticated users | Grafana Viewer, basic app access |

**Benefits:**
- 2 groups instead of 2 per app
- Add user to `Admins` once = admin everywhere
- Simpler role_attribute_path expressions

### Network Architecture Note

**Important:** For OIDC apps, use internal cluster URLs for server-side calls:
- **Browser redirects** (auth_url, signout_redirect_url): External URL (`https://authentik.jardoole.xyz/...`)
- **Server-side calls** (token_url, api_url): Internal URL (`http://authentik-server.authentik.svc.cluster.local/...`)

This avoids network policy issues where pods can't reach external IPs.

### Services Configured (Code Changes Complete)

| Service | Auth Method | Status |
|---------|-------------|--------|
| Grafana | OIDC Native | Needs Authentik setup |
| Prometheus | Forward Auth | Needs Authentik setup |
| Alertmanager | Forward Auth | Needs Authentik setup |
| Backrest | Forward Auth | Needs Authentik setup |
| Sonarr | Forward Auth + API Bypass | Needs Authentik setup |
| Radarr | Forward Auth + API Bypass | Needs Authentik setup |
| Prowlarr | Forward Auth + API Bypass | Needs Authentik setup |

### Services Pending (Future Work)

| Service | Auth Method | Notes |
|---------|-------------|-------|
| Jellyseerr | OIDC Native | Configure in app UI |
| qBittorrent | Forward Auth | Needs subnet bypass |
| Jellyfin | OIDC Plugin | Requires plugin install |
| Homepage | Forward Auth | Widget config needed |
| Headlamp | OIDC + K8s RBAC | Most complex |

---

## Prerequisites

### 1. Deploy Platform Foundation Update

The forward auth middleware was added to the platform foundation playbook.

```bash
make k3s-platform-foundation
```

This creates the `authentik-forward-auth` middleware in `kube-system` namespace.

### 2. Create Embedded Outpost in Authentik

The embedded outpost provides the forward auth endpoint.

1. Login to Authentik: https://authentik.jardoole.xyz
2. Navigate to **Admin Interface** → **Outposts**
3. The default embedded outpost should already exist
4. Verify it shows "Type: Proxy" and is healthy

If no embedded outpost exists:
1. Click **Create**
2. Name: `authentik Embedded Outpost`
3. Type: `Proxy`
4. Integration: Leave empty (uses embedded)
5. Click **Create**

### 3. Understanding Secret Generation

**For OIDC apps (Grafana, Jellyseerr, etc.):**
- Authentik auto-generates `Client ID` and `Client Secret` when creating an OAuth2 Provider
- Copy these values from Authentik UI → store in Ansible Vault
- The app uses these credentials to authenticate with Authentik

**For Forward Auth apps (Prometheus, Sonarr, etc.):**
- No secrets needed in your vault
- Authentication is handled entirely by Authentik via the Traefik middleware
- Users authenticate through Authentik's login page

### 4. Granting Application Access (Required for All Apps)

**Important:** Creating an application in Authentik does not automatically grant access to users.
You must explicitly bind groups (or users) to each application.

After creating any application:

1. Go to **Admin Interface** → **Applications** → **Applications**
2. Click on the application (e.g., Grafana)
3. Go to the **Policy / Group / User Bindings** tab
4. Click **Bind existing group**
5. Select `Admins` → Click **Create**
6. Click **Bind existing group** again
7. Select `Users` → Click **Create**

This grants access to both groups. The **Policy engine mode** should be set to **any**
(user needs to match ANY binding to access).

**Note:** For Forward Auth apps, you must also add the application to the embedded outpost
(see app-specific instructions).

---

## Phase 1: Grafana (OIDC Native)

Grafana uses native OIDC integration - the most secure method.

**Important:** The application slug must be `grafana` (configured in Step 3) because the logout URL in `values.yml` references it: `https://authentik.jardoole.xyz/application/o/grafana/end-session/`

### Step 1: Create Authentik Provider (generates secrets)

1. Go to **Admin Interface** → **Applications** → **Providers**
2. Click **Create**
3. Select **OAuth2/OpenID Provider**
4. Configure:
   - **Name**: `grafana`
   - **Authentication flow**: default-authentication-flow
   - **Authorization flow**: default-provider-authorization-implicit-consent
   - **Client type**: Confidential
   - **Redirect URIs**: `https://grafana.jardoole.xyz/login/generic_oauth`
   - **Post Logout Redirect URIs**: `https://grafana.jardoole.xyz/login/generic_oauth`
   - **Signing Key**: Select any available key (e.g., `authentik Self-signed Certificate`)
   - **Scopes**: Hold Ctrl and select `openid`, `profile`, `email`, `groups` (groups needed for role mapping)
5. Click **Finish**

6. **Copy the generated credentials:**
   - Click on the newly created `grafana` provider
   - Copy **Client ID** (e.g., `a1b2c3d4e5f6...`)
   - Copy **Client Secret** (click the eye icon to reveal, e.g., `x9y8z7w6v5u4...`)

### Step 2: Add Secrets to Vault

```bash
uv run ansible-vault edit group_vars/all/vault.yml
```

Add the copied values:
```yaml
vault_authentik_grafana_client_id: "paste-client-id-here"
vault_authentik_grafana_client_secret: "paste-client-secret-here"
```

### Step 3: Create Authentik Application

1. Go to **Admin Interface** → **Applications** → **Applications**
2. Click **Create**
3. Configure:
   - **Name**: `Grafana`
   - **Slug**: `grafana`
   - **Provider**: Select `grafana` (created in Step 1)
   - **Launch URL**: `https://grafana.jardoole.xyz`
4. Click **Create**

### Step 4: Grant Application Access

Bind groups to the application (see [Prerequisites: Granting Application Access](#4-granting-application-access-required-for-all-apps)):

1. Click on the Grafana application → **Policy / Group / User Bindings**
2. Bind both `Admins` and `Users` groups

**One-time setup:** If groups don't exist yet, create them first:
1. Go to **Directory** → **Groups**
2. Create `Admins` and `Users` groups
3. Add users to appropriate groups

Role mapping (configured in values.yml):
- Users in `Admins` → Grafana Admin role
- All other authenticated users → Grafana Viewer role

### Step 5: Deploy

Deploy the monitoring stack (this applies the vault secrets):

```bash
make app-deploy APP=kube-prometheus-stack
```

### Step 6: Verify

1. Open https://grafana.jardoole.xyz
2. Click "Sign in with Authentik"
3. Authenticate with Authentik
4. Verify correct role assignment

---

## Phase 2: Prometheus (Forward Auth)

Prometheus uses forward auth - requests are validated by Authentik before reaching the app.

### Step 1: Create Authentik Provider

1. Go to **Admin Interface** → **Applications** → **Providers**
2. Click **Create**
3. Select **Proxy Provider**
4. Configure:
   - **Name**: `prometheus`
   - **Authentication flow**: default-authentication-flow
   - **Authorization flow**: default-provider-authorization-implicit-consent
   - **Mode**: **Forward auth (single application)**
   - **External host**: `https://prometheus.jardoole.xyz`
5. Click **Finish**

### Step 2: Create Authentik Application

1. Go to **Admin Interface** → **Applications** → **Applications**
2. Click **Create**
3. Configure:
   - **Name**: `Prometheus`
   - **Slug**: `prometheus`
   - **Provider**: Select `prometheus`
   - **Launch URL**: `https://prometheus.jardoole.xyz`
4. Click **Create**

### Step 3: Add to Outpost

1. Go to **Admin Interface** → **Outposts**
2. Edit the embedded outpost
3. Under **Applications**, add `Prometheus`
4. Click **Update**

### Step 4: Deploy

```bash
make app-deploy APP=kube-prometheus-stack
```

### Step 5: Verify

1. Open https://prometheus.jardoole.xyz
2. Should redirect to Authentik login
3. After authentication, access Prometheus UI

---

## Phase 3: Alertmanager (Forward Auth)

Same pattern as Prometheus.

### Step 1: Create Authentik Provider

1. Go to **Providers** → **Create** → **Proxy Provider**
2. Configure:
   - **Name**: `alertmanager`
   - **Mode**: Forward auth (single application)
   - **External host**: `https://alert-manager.jardoole.xyz`
3. Click **Finish**

### Step 2: Create Authentik Application

1. Go to **Applications** → **Create**
2. Configure:
   - **Name**: `Alertmanager`
   - **Slug**: `alertmanager`
   - **Provider**: Select `alertmanager`
   - **Launch URL**: `https://alert-manager.jardoole.xyz`
3. Click **Create**

### Step 3: Add to Outpost

1. Edit embedded outpost
2. Add `Alertmanager` to applications
3. Click **Update**

### Step 4: Verify

1. Open https://alert-manager.jardoole.xyz
2. Should redirect to Authentik login

---

## Phase 4: Backrest (Forward Auth)

### Step 1: Create Authentik Provider

1. Go to **Providers** → **Create** → **Proxy Provider**
2. Configure:
   - **Name**: `backrest`
   - **Mode**: Forward auth (single application)
   - **External host**: `https://backrest.jardoole.xyz`
3. Click **Finish**

### Step 2: Create Authentik Application

1. Go to **Applications** → **Create**
2. Configure:
   - **Name**: `Backrest`
   - **Slug**: `backrest`
   - **Provider**: Select `backrest`
   - **Launch URL**: `https://backrest.jardoole.xyz`
3. Click **Create**

### Step 3: Add to Outpost

1. Edit embedded outpost
2. Add `Backrest` to applications
3. Click **Update**

### Step 4: Deploy

```bash
make app-deploy APP=backrest
```

### Step 5: Verify

1. Open https://backrest.jardoole.xyz
2. Should redirect to Authentik login

---

## Phase 5-7: Sonarr, Radarr, Prowlarr (Forward Auth + API Bypass)

These apps need API bypass for inter-app communication (Prowlarr → Sonarr/Radarr).

### Step 1: Create API Bypass Policy

Create a policy that allows unauthenticated API access:

1. Go to **Admin Interface** → **Customization** → **Policies**
2. Click **Create** → **Expression Policy**
3. Configure:
   - **Name**: `api-bypass`
   - **Expression**:
     ```python
     return request.http_request.path.startswith('/api')
     ```
4. Click **Create**

### Step 2: Create Provider for Each App

For **Sonarr**:
1. **Providers** → **Create** → **Proxy Provider**
2. Configure:
   - **Name**: `sonarr`
   - **Mode**: Forward auth (single application)
   - **External host**: `https://sonarr.jardoole.xyz`
3. Click **Finish**

Repeat for **Radarr** (`https://radarr.jardoole.xyz`) and **Prowlarr** (`https://prowlarr.jardoole.xyz`).

### Step 3: Create Applications

For **Sonarr**:
1. **Applications** → **Create**
2. Configure:
   - **Name**: `Sonarr`
   - **Slug**: `sonarr`
   - **Provider**: Select `sonarr`
   - **Launch URL**: `https://sonarr.jardoole.xyz`
3. Click **Create**

Repeat for Radarr and Prowlarr.

### Step 4: Bind API Bypass Policy

For each application (Sonarr, Radarr, Prowlarr):

1. Go to the application → **Policy / Group / User Bindings**
2. Click **Bind existing policy**
3. Select `api-bypass` policy
4. **Important**: Check "Negate result" = OFF and "Failure result" = "Don't pass"
5. Set **Order** to `-1` (runs first)

This allows `/api/*` requests to bypass authentication.

### Step 5: Add to Outpost

1. Edit embedded outpost
2. Add `Sonarr`, `Radarr`, `Prowlarr` to applications
3. Click **Update**

### Step 6: Deploy

```bash
make app-deploy APP=sonarr
make app-deploy APP=radarr
make app-deploy APP=prowlarr
```

### Step 7: Verify

1. Open https://sonarr.jardoole.xyz - should require login
2. Test API access (should work without auth):
   ```bash
   curl -H "X-Api-Key: YOUR_API_KEY" https://sonarr.jardoole.xyz/api/v3/system/status
   ```

---

## Troubleshooting

### Forward Auth Returns 500

1. Check Authentik server logs:
   ```bash
   kubectl logs -n authentik -l app.kubernetes.io/name=authentik-server
   ```

2. Verify middleware is created:
   ```bash
   kubectl get middleware -n kube-system authentik-forward-auth -o yaml
   ```

3. Verify outpost is healthy:
   - Authentik Admin → Outposts → Check status

### OIDC Login Fails

1. Verify redirect URI matches exactly
2. Check Grafana logs:
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana
   ```

3. Verify secret contains correct values:
   ```bash
   kubectl get secret -n monitoring grafana-authentik-oidc -o yaml
   ```

### OIDC "Failed to get token from provider"

This usually means the app can't reach Authentik for server-side OAuth calls.

**Solution:** Use internal cluster URLs for `token_url` and `api_url`:
```yaml
# Browser redirect - external URL (user's browser navigates here)
auth_url: https://authentik.jardoole.xyz/application/o/authorize/
# Server-side calls - internal cluster URLs (avoids network policy issues)
token_url: http://authentik-server.authentik.svc.cluster.local/application/o/token/
api_url: http://authentik-server.authentik.svc.cluster.local/application/o/userinfo/
```

The pod can't reach the external IP, but can reach the internal service.

### API Bypass Not Working

1. Verify policy expression is correct
2. Check policy binding order (should be -1 or lowest)
3. Test with curl to confirm API path format

---

## Rollback

To disable Authentik auth for a service:

1. Remove `traefik.ingress.kubernetes.io/router.middlewares` annotation
2. Redeploy the application

For Grafana OIDC, set in values.yml:
```yaml
grafana:
  grafana.ini:
    auth.generic_oauth:
      enabled: false
```

---

## Next Steps (Future Work)

After these services are working:

1. **qBittorrent** - Forward auth with subnet bypass
2. **Jellyseerr** - Native OIDC (configure in app UI)
3. **Jellyfin** - OIDC plugin installation required
4. **Homepage** - Forward auth + widget API config
5. **Headlamp** - OIDC + Kubernetes RBAC integration
