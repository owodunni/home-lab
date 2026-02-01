# Nextcloud OIDC Authentication - Issue Log

This document tracks the diagnosis and fixes for Nextcloud OIDC authentication with Authentik.

---

## Issue Summary

**Symptom**: OIDC login button in Nextcloud UI fails with "Could not connect to OIDC provider"

**Environment**:
- Nextcloud deployed via Helm in K3s cluster
- Authentik as OIDC provider
- Traefik as ingress controller
- NetworkPolicy restricting Nextcloud egress

---

## Fix 1: NetworkPolicy Port Mismatch

**Date**: 2026-02-01

**Problem**: NetworkPolicy allowed egress to Traefik on service ports (80/443), but NetworkPolicy evaluates pod ports (8000/8443).

**Diagnosis**:
```bash
# From pod WITHOUT NetworkPolicy - SUCCESS
kubectl run test-pod --image=curlimages/curl --rm -it -- curl http://10.42.2.3:8000
# Result: 404 (connected)

# From nextcloud pod WITH NetworkPolicy - BLOCKED
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- curl http://10.42.2.3:8000
# Result: Connection refused
```

**Root Cause**: When kube-proxy rewrites `ClusterIP:443` to `PodIP:8443`, NetworkPolicy evaluates the destination pod port (8443), not the service port (443). The policy only allowed 80/443, so connections were blocked.

**Fix Applied**: Changed `apps/nextcloud/prerequisites.yml`:
```yaml
# Before (broken):
ports:
  - port: 443
    protocol: TCP
  - port: 80
    protocol: TCP

# After (fixed):
ports:
  - port: 8443   # Traefik websecure targetPort
    protocol: TCP
  - port: 8000   # Traefik web targetPort
    protocol: TCP
```

**Result**: ✅ Network connectivity now works - Nextcloud can reach Traefik and Authentik

**Verification**:
```bash
# Traefik connectivity - SUCCESS
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- curl http://10.42.2.3:8000
# Result: HTTP 404 (connected!)

# OIDC discovery - SUCCESS
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- \
  curl https://authentik.jardoole.xyz/application/o/nextcloud/.well-known/openid-configuration
# Result: HTTP 200 with full OIDC config JSON
```

---

## Current Status

| Component | Status | Notes |
|-----------|--------|-------|
| NetworkPolicy | ✅ Fixed | Ports 8000/8443 for Traefik |
| hostAliases | ✅ Working | authentik.jardoole.xyz → Traefik ClusterIP |
| DNS resolution | ✅ Working | /etc/hosts entry present |
| OIDC discovery | ✅ Accessible | Returns HTTP 200 |
| user_oidc app | ✅ Installed | Version 8.3.0, provider configured |
| OIDC Login | ⚠️ Partial | Redirects work, state mismatch on callback |
| Redis sessions | ❌ Broken | Password contains URL-breaking characters |

---

## Fix 2: Local Access Rules Violation

**Date**: 2026-02-01

**Problem**: Despite network connectivity working, OIDC login still fails.

**Diagnosis**: Nextcloud logs reveal:
```
Host "192.168.1.23" (authentik.jardoole.xyz:80) violates local access rules
```

**Root Cause**: Nextcloud has a security feature that blocks HTTP requests to local/private IP addresses (RFC 1918). Even though the network path is working, Nextcloud's application-level security rejects requests to private IPs.

**Fix Applied**: Added `'allow_local_remote_servers' => true` to `apps/nextcloud/values.yml`:
```php
$CONFIG = [
  'default_phone_region' => 'AU',
  'maintenance_window_start' => 1,
  'allow_local_remote_servers' => true,  // Allow OIDC to private IPs
];
```

**Status**: ✅ Applied - awaiting deployment

---

## Fix 3: Redis Password URL Encoding Issue

**Date**: 2026-02-01

**Problem**: After OIDC connectivity was fixed, login flow redirects to Authentik successfully, but callback fails with "the receiver state did not match the expected value".

**Diagnosis**:
- OIDC state is stored in PHP session
- PHP session uses Redis via `session.save_path = "tcp://...?auth=PASSWORD"`
- Redis password contains URL-special characters: `+`, `/`, `=`
- Password is NOT URL-encoded in the save_path
- PHP URL parser breaks the password, causing Redis auth to fail
- Sessions are lost between requests, so OIDC state cannot be retrieved

**Root Cause**: The password `Qy+/KnXgk4Uvef3iRAQUNWamVWaEUeCwCo/X1e9uLbE=` breaks URL parsing:
- `+` becomes a space
- `/` is interpreted as path separator
- `=` confuses query string parsing

**Fix Required**: Regenerate Redis password with URL-safe alphanumeric characters only.

```bash
# Generate URL-safe password
openssl rand -hex 16

# Update vault
uv run ansible-vault edit group_vars/all/vault.yml
# Change vault_nextcloud_redis_password to the new value

# Redeploy
make app-deploy APP=nextcloud
```

**Status**: 🔧 Pending - user action required

---

## Deployment Commands

```bash
# Deploy changes
make app-deploy APP=nextcloud

# Verify NetworkPolicy
kubectl get networkpolicy -n nextcloud allow-nextcloud-egress -o yaml

# Test OIDC from pod
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- \
  curl https://authentik.jardoole.xyz/application/o/nextcloud/.well-known/openid-configuration

# Check Nextcloud logs
kubectl logs -n nextcloud deploy/nextcloud -c nextcloud --tail=100
```
