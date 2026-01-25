# Authentik SSO Migration Guide

Step-by-step guide to enable Authentik authentication for home lab services.

## Overview

This guide covers migrating services to use Authentik for centralized authentication.

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

---

## Phase 1: Grafana (OIDC Native)

Grafana uses native OIDC integration - the most secure method.

### Step 1: Add Vault Secrets

Add these secrets to your vault (run locally, not in Claude):

```bash
uv run ansible-vault edit group_vars/all/vault.yml
```

Add:
```yaml
vault_authentik_grafana_client_id: "<will be generated>"
vault_authentik_grafana_client_secret: "<will be generated>"
```

### Step 2: Create Authentik Provider

1. Go to **Admin Interface** → **Applications** → **Providers**
2. Click **Create**
3. Select **OAuth2/OpenID Provider**
4. Configure:
   - **Name**: `grafana`
   - **Authentication flow**: default-authentication-flow
   - **Authorization flow**: default-provider-authorization-implicit-consent
   - **Client type**: Confidential
   - **Client ID**: Copy this value → `vault_authentik_grafana_client_id`
   - **Client Secret**: Copy this value → `vault_authentik_grafana_client_secret`
   - **Redirect URIs**: `https://grafana.jardoole.xyz/login/generic_oauth`
   - **Signing Key**: Select any available key
   - **Scopes**: Select `openid`, `profile`, `email`
5. Click **Finish**

### Step 3: Create Authentik Application

1. Go to **Admin Interface** → **Applications** → **Applications**
2. Click **Create**
3. Configure:
   - **Name**: `Grafana`
   - **Slug**: `grafana`
   - **Provider**: Select `grafana` (created above)
   - **Launch URL**: `https://grafana.jardoole.xyz`
4. Click **Create**

### Step 4: Create Authentik Groups (Optional but Recommended)

For role mapping to work:

1. Go to **Directory** → **Groups**
2. Create group: `Grafana Admins`
3. Create group: `Grafana Editors`
4. Add users to appropriate groups

Role mapping (configured in values.yml):
- Users in `Grafana Admins` → Admin role
- Users in `Grafana Editors` → Editor role
- All other authenticated users → Viewer role

### Step 5: Update Vault and Deploy

1. Update vault with the Client ID and Secret from Step 2
2. Deploy the monitoring stack:

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
