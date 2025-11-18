# Tailscale Setup Guide

**Last Updated**: 2025-11-18
**Applies To**: pfSense 2.7+, Debian-based systems
**Tailscale Version**: 1.56+

## Overview

This guide covers Tailscale installation and configuration for the home lab infrastructure, implementing the hybrid approach:
- **pfSense**: Tailscale subnet router (advertises LAN + IoT VLANs)
- **MinIO**: Tailscale direct node (offsite backup target)
- **Clients**: Laptop, mobile devices

**Goal**: Secure remote access to home lab and offsite backup connectivity.

---

## Prerequisites

- Tailscale account (free tier supports 100 devices, 3 users)
- pfSense 2.7+ with internet access
- MinIO server (pi-cm5-4) with Debian/Ubuntu
- Admin access to pfSense and MinIO
- Network topology documentation (for IP planning)

---

## Part 1: Tailscale Account Setup

### 1.1 Create Tailscale Account

1. Visit https://login.tailscale.com/start
2. Sign up with email or OAuth provider (GitHub, Google, Microsoft)
3. Verify email
4. Complete initial setup wizard

### 1.2 Enable MagicDNS (Recommended)

MagicDNS provides automatic DNS names for all Tailscale nodes.

1. Go to https://login.tailscale.com/admin/dns
2. Click "Enable MagicDNS"
3. (Optional) Add global nameservers: `1.1.1.1`, `8.8.8.8`
4. Save changes

**Result**: Nodes accessible via `<hostname>.tailnet-name.ts.net`

### 1.3 Generate Pre-Auth Keys

Pre-auth keys allow non-interactive node registration.

#### Subnet Router Key (pfSense)

1. Go to https://login.tailscale.com/admin/settings/keys
2. Click "Generate auth key"
3. Settings:
   - **Reusable**: ✅ Yes (in case of pfSense reinstall)
   - **Ephemeral**: ❌ No (node persists after disconnect)
   - **Pre-approved**: ✅ Yes (auto-approve routes)
   - **Tags**: `tag:subnet-router`
4. Copy key → save to vault_passwords/tailscale-subnet-key.txt (gitignored)

#### MinIO Direct Node Key

1. Generate another auth key
2. Settings:
   - **Reusable**: ❌ No (single-use)
   - **Ephemeral**: ❌ No
   - **Pre-approved**: ✅ Yes
   - **Tags**: `tag:offsite-nas`
3. Copy key → save to vault_passwords/tailscale-minio-key.txt (gitignored)

---

## Part 2: Install Tailscale on pfSense

### 2.1 Install Tailscale Package

1. Login to pfSense WebUI: `https://192.168.92.1`
2. Navigate to **System → Package Manager → Available Packages**
3. Search for "tailscale"
4. Click **Install** next to `tailscale` package
5. Confirm installation
6. Wait for completion (1-2 minutes)

### 2.2 Initial Tailscale Configuration

1. Navigate to **VPN → Tailscale → Settings**
2. Configuration:
   - **Enable**: ✅ Checked
   - **Auth Key**: Paste subnet router pre-auth key
   - **Advertise Routes**: `192.168.92.0/24,192.168.0.0/24,192.168.10.0/24`
   - **Accept Routes**: ❌ Unchecked (we're advertising, not receiving)
   - **Exit Node**: ❌ Unchecked (not routing all internet traffic)
   - **Accept DNS**: ✅ Checked (use MagicDNS)
3. Click **Save**

### 2.3 Start Tailscale Service

1. Navigate to **Status → Services**
2. Find "tailscale" service
3. Click **Start** (green play button)
4. Verify status shows "Running" (green checkmark)

### 2.4 Verify pfSense Tailscale IP

```bash
# SSH to pfSense (or use shell via WebUI)
ssh admin@192.168.92.1

# Check Tailscale status
tailscale status

# Expected output:
# 100.64.0.1   pfsense              user@    linux   -
# ...subnet routes: 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24
```

**Note**: Tailscale IP (e.g., 100.64.0.1) will be different - this is auto-assigned.

### 2.5 Approve Subnet Routes (Tailscale Admin Console)

1. Go to https://login.tailscale.com/admin/machines
2. Find "pfsense" node in list
3. Click the **⋮** menu → **Edit route settings**
4. You should see:
   - ⚠️ `192.168.92.0/24` (pending approval)
   - ⚠️ `192.168.0.0/24` (pending approval)
   - ⚠️ `192.168.10.0/24` (pending approval)
5. Click **Approve** for all three routes
6. Verify routes show ✅ status

**Result**: Tailscale clients can now access devices on 192.168.92.0/24 (LAN), 192.168.0.0/24 (IoT), and 192.168.10.0/24 (Guest).

### 2.6 Configure pfSense Firewall for Tailscale

Create firewall rules to allow Tailscale traffic:

#### Allow Tailscale to LAN

1. Navigate to **Firewall → Rules → Tailscale** (tab will appear after Tailscale enabled)
2. Click **Add** (up arrow for top of list)
3. Settings:
   - **Action**: Pass
   - **Interface**: Tailscale
   - **Protocol**: Any
   - **Source**: Tailscale net
   - **Destination**: LAN net
   - **Description**: "Allow Tailscale clients to access LAN"
4. Click **Save**

#### Allow Tailscale to IoT (Admin Access)

1. Add another rule:
   - **Action**: Pass
   - **Interface**: Tailscale
   - **Protocol**: Any
   - **Source**: Tailscale net
   - **Destination**: IoT net (192.168.0.0/24)
   - **Description**: "Allow Tailscale clients to manage IoT devices"
2. Click **Save**

#### Allow Tailscale to Guest (Admin Access)

1. Add another rule:
   - **Action**: Pass
   - **Interface**: Tailscale
   - **Protocol**: Any
   - **Source**: Tailscale net
   - **Destination**: Guest net (192.168.10.0/24)
   - **Description**: "Allow Tailscale clients to manage Guest network"
2. Click **Save**

#### Apply Changes

1. Click **Apply Changes** button at top

---

## Part 3: Install Tailscale on MinIO Server

### 3.1 Install Tailscale (Debian/Ubuntu)

SSH to MinIO server:

```bash
ssh pi@pi-cm5-4.local

# Download and run Tailscale install script
curl -fsSL https://tailscale.com/install.sh | sh

# Expected output:
# Installing Tailscale...
# Tailscale installed successfully!
```

### 3.2 Authenticate MinIO Node

```bash
# Start Tailscale with pre-auth key
sudo tailscale up --auth-key=tskey-auth-XXXXX --advertise-tags=tag:offsite-nas

# Replace tskey-auth-XXXXX with actual key from vault_passwords/tailscale-minio-key.txt

# Expected output:
# Success.
```

### 3.3 Verify MinIO Tailscale IP

```bash
# Check Tailscale status
tailscale status

# Expected output:
# 100.64.0.10  pi-cm5-4             user@    linux   -
# 100.64.0.1   pfsense              user@    linux   active; direct 192.168.92.1:41641

# Check IP address
tailscale ip -4

# Expected output:
# 100.64.0.10
```

**Record this IP** - you'll use it in Longhorn backup configuration.

### 3.4 Test Connectivity

```bash
# From MinIO, ping pfSense Tailscale IP
ping 100.64.0.1

# From MinIO, try to ping K3s node LAN IP (should FAIL per ACLs)
ping 192.168.92.11

# Expected: "Destination unreachable" or timeout (ACLs blocking)
```

---

## Part 4: Configure Tailscale ACLs

Access Control Lists (ACLs) define who can access what in your Tailnet.

### 4.1 Edit ACL Policy

1. Go to https://login.tailscale.com/admin/acls
2. Click **Edit ACL**
3. Replace default policy with:

```json
{
  "groups": {
    "group:admins": ["user@example.com"]
  },
  "tagOwners": {
    "tag:subnet-router": ["group:admins"],
    "tag:offsite-nas": ["group:admins"],
    "tag:k3s-node": ["group:admins"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["group:admins"],
      "dst": [
        "*:22",
        "*:443",
        "*:6443",
        "tag:offsite-nas:9000,9001"
      ]
    },
    {
      "action": "accept",
      "src": ["192.168.92.0/24"],
      "dst": ["tag:offsite-nas:9000,9001"]
    },
    {
      "action": "accept",
      "src": ["group:admins"],
      "dst": ["192.168.92.0/24:*", "192.168.0.0/24:*", "192.168.10.0/24:*"]
    }
  ],
  "ssh": [
    {
      "action": "accept",
      "src": ["group:admins"],
      "dst": ["tag:subnet-router", "tag:offsite-nas"],
      "users": ["autogroup:nonroot", "root"]
    }
  ]
}
```

4. Click **Save**

**Replace `user@example.com`** with your actual Tailscale account email.

### 4.2 ACL Explanation

| ACL Rule | Meaning |
|----------|---------|
| `group:admins → *:22,443,6443` | Admins can SSH (22), HTTPS (443), and access K8s API (6443) on all nodes |
| `group:admins → tag:offsite-nas:9000,9001` | Admins can access MinIO S3 API (9000) and Console (9001) |
| `192.168.92.0/24 → tag:offsite-nas:9000,9001` | K3s cluster (LAN VLAN) can push backups to MinIO |
| `group:admins → 192.168.92.0/24:*` | Admins can access any service on LAN VLAN via subnet router |
| `group:admins → 192.168.0.0/24:*` | Admins can access IoT devices via subnet router |
| `group:admins → 192.168.10.0/24:*` | Admins can access Guest network via subnet router |

**Key Security Features**:
- MinIO **cannot** initiate connections back to cluster (deny-by-default)
- Only admins have SSH access
- K3s cluster has limited access (S3 API only, no SSH)

### 4.3 Test ACLs

From your laptop (with Tailscale installed):

```bash
# Test SSH to MinIO
ssh pi@100.64.0.10
# Should succeed (admin access allowed)

# Test MinIO S3 API
curl http://100.64.0.10:9000
# Should return XML (S3 API endpoint)

# Test K3s node access via subnet router
ping 192.168.92.11
# Should succeed (admin has access to LAN VLAN)

# Test K3s SSH
ssh pi@192.168.92.11
# Should succeed (admin access allowed)
```

From MinIO (SSH session):

```bash
# Try to ping K3s node
ping 192.168.92.11
# Should FAIL (MinIO cannot access LAN VLAN)

# Try to SSH to K3s node
ssh pi@192.168.92.11
# Should FAIL (ACL blocks this direction)
```

**If tests fail**: Review ACLs, check Tailscale status on both nodes.

---

## Part 5: Install Tailscale on Client Devices

### 5.1 Install on Laptop (Linux)

```bash
# Download and install
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale
sudo tailscale up

# Login via browser
# Follow URL provided in terminal output

# Verify connection
tailscale status
```

### 5.2 Install on Mobile (Android/iOS)

1. Install Tailscale app from Play Store / App Store
2. Open app → Sign in with your Tailscale account
3. Grant VPN permissions
4. Verify "Connected" status in app

### 5.3 Verify Client Access

From laptop/mobile:

```bash
# Ping pfSense via Tailscale
ping 100.64.0.1

# Access K3s node via subnet router
ping 192.168.92.11

# Access MinIO S3 Console (browser)
# Open: http://100.64.0.10:9001
```

---

## Part 6: Update Longhorn Backup Target

Now that MinIO is accessible via Tailscale, update Longhorn to use Tailscale IP.

### 6.1 Get MinIO Tailscale IP

```bash
# SSH to MinIO
ssh pi@pi-cm5-4.local

# Get Tailscale IP
tailscale ip -4

# Example output: 100.64.0.10
```

### 6.2 Update Longhorn Settings

1. Access Longhorn UI: `https://longhorn.jardoole.xyz`
2. Navigate to **Settings → General**
3. Find "Backup Target" setting
4. Update value:
   ```
   # Before (local network):
   s3://longhorn-backups@us-east-1/
   http://pi-cm5-4.local:9000

   # After (Tailscale):
   s3://longhorn-backups@us-east-1/
   http://100.64.0.10:9000
   ```
5. Click **Save**

### 6.3 Test Backup

1. In Longhorn UI, select a volume
2. Click **Create Backup**
3. Wait for backup to complete (check status)
4. Verify backup appears in MinIO:
   ```bash
   # SSH to MinIO
   mc ls minio/longhorn-backups/
   # Should show backup files
   ```

**Success**: Longhorn now backs up to MinIO via Tailscale!

---

## Part 7: Monitoring & Maintenance

### 7.1 Check Tailscale Node Status

**Admin Console**:
- Visit https://login.tailscale.com/admin/machines
- Green checkmark = node online
- Yellow warning = node offline or needs attention
- Click node for details (last seen, Tailscale version, routes)

**Command Line** (from any Tailscale node):

```bash
# Show all nodes in tailnet
tailscale status

# Ping specific node
tailscale ping 100.64.0.10

# Show routes
tailscale status --json | jq '.Peer[] | select(.AdvertisedRoutes) | {Hostname, Routes:.AdvertisedRoutes}'
```

### 7.2 Monitor DERP Relay Usage

Tailscale uses DERP relays when direct connection fails (NAT traversal issues).

**Check connection type**:

```bash
tailscale status

# Look for connection status:
# - "direct" = optimal (WireGuard directly)
# - "relay DERP-XX" = using relay (slower, higher latency)
```

**Goal**: Most connections should be "direct" for best performance.

**If seeing relay usage**:
- pfSense has "hard NAT" (Endpoint-Dependent Mapping) → expected for subnet router
- MinIO should be "direct" from clients (it's a direct node)

### 7.3 Update Tailscale

**pfSense**:
1. System → Package Manager → Installed Packages
2. Find "tailscale" → click **Update** if available

**MinIO / Linux**:
```bash
sudo apt update && sudo apt upgrade tailscale
```

**Clients**:
- Linux: `sudo apt upgrade tailscale`
- Mobile: Update via app store

### 7.4 Rotate Auth Keys

Auth keys should be rotated periodically (every 90-180 days).

1. Generate new pre-auth keys (see Part 1.3)
2. Update pfSense Tailscale config with new key
3. Restart Tailscale service on pfSense
4. Revoke old keys in Tailscale admin console

---

## Troubleshooting

### Issue: pfSense Tailscale Service Won't Start

**Symptoms**: Service shows "Stopped" in Status → Services

**Diagnosis**:
```bash
# SSH to pfSense
ssh admin@192.168.92.1

# Check Tailscale logs
tail -f /var/log/tailscaled.log

# Check for errors
grep -i error /var/log/tailscaled.log
```

**Common Causes**:
1. **Invalid auth key**: Generate new key, update config
2. **Firewall blocking Tailscale**: Ensure WAN rules allow UDP 41641 (Tailscale default)
3. **Package corruption**: Reinstall tailscale package

**Solution**:
```bash
# Restart service
/usr/local/etc/rc.d/tailscale restart

# Re-authenticate if needed
tailscale up --auth-key=NEW_KEY
```

---

### Issue: Subnet Routes Not Approved

**Symptoms**: Routes show ⚠️ in Tailscale admin console

**Solution**:
1. Go to https://login.tailscale.com/admin/machines
2. Click pfSense node → Edit route settings
3. Manually approve each route

**Prevention**: Use `--accept-routes` flag and pre-approved auth keys.

---

### Issue: Cannot Access LAN from Tailscale Client

**Symptoms**: Laptop can ping 100.64.0.1 (pfSense Tailscale IP) but not 192.168.92.11 (K3s node)

**Diagnosis**:
```bash
# From laptop
tailscale status

# Check if subnet routes visible
# Should show: "192.168.92.0/24 via 100.64.0.1"

# Test routing
traceroute 192.168.92.11
```

**Common Causes**:
1. Subnet routes not approved (see above)
2. pfSense firewall blocks Tailscale → LAN (check Part 2.6)
3. ACLs block access (check Part 4)

**Solution**:
```bash
# Verify ACLs allow access
# https://login.tailscale.com/admin/acls

# Check pfSense firewall logs
# Firewall → Logs → Firewall
# Look for blocks from Tailscale interface
```

---

### Issue: MinIO Cannot Be Reached via Tailscale

**Symptoms**: `curl http://100.64.0.10:9000` times out from laptop

**Diagnosis**:
```bash
# From laptop
tailscale ping 100.64.0.10

# Expected: Response from MinIO
# If no response: MinIO Tailscale down or ACLs blocking

# From MinIO
tailscale status

# Expected: "active; direct" or "active; relay"
```

**Common Causes**:
1. MinIO Tailscale service stopped
2. MinIO firewall (ufw) blocks ports 9000/9001
3. ACLs deny access (check group:admins membership)

**Solution**:
```bash
# On MinIO, restart Tailscale
sudo systemctl restart tailscaled

# Check firewall
sudo ufw status

# If blocking, allow Tailscale interface
sudo ufw allow in on tailscale0
```

---

### Issue: ACL Denies Expected Access

**Symptoms**: Access should work per ACLs but connection refused/timeout

**Diagnosis**:
1. Go to https://login.tailscale.com/admin/acls
2. Click **Test ACLs** tab
3. Enter:
   - **Source**: Your Tailscale email
   - **Destination**: MinIO Tailscale IP:port (e.g., `100.64.0.10:9000`)
4. Click **Test**

**Expected**: "✅ Allowed"

**If blocked**: Review ACL syntax, check group memberships.

**Common Mistakes**:
- Forgot to add yourself to `group:admins`
- Typo in ACL (e.g., `tag:offiste-nas` instead of `tag:offsite-nas`)
- ACL order matters (earlier rules evaluated first)

---

## Security Best Practices

### 1. Use Tags for Node Authorization

**Good**:
```json
{
  "acls": [{
    "action": "accept",
    "src": ["group:admins"],
    "dst": ["tag:offsite-nas:9000"]
  }]
}
```

**Bad** (hardcoded IPs):
```json
{
  "acls": [{
    "action": "accept",
    "src": ["user@example.com"],
    "dst": ["100.64.0.10:9000"]
  }]
}
```

**Why**: Tags are portable, IPs can change.

### 2. Principle of Least Privilege

Grant minimum necessary access:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:k3s-node"],
      "dst": ["tag:offsite-nas:9000,9001"]
    }
  ]
}
```

**Do NOT**:
```json
{
  "acls": [{
    "action": "accept",
    "src": ["tag:k3s-node"],
    "dst": ["tag:offsite-nas:*"]
  }]
}
```

**Why**: Limit attack surface (only S3 API, not SSH).

### 3. Enable Key Expiry

For interactive logins (laptop, mobile), use ephemeral keys that expire:

1. Login to device: `tailscale up`
2. In Tailscale admin console, set key expiry to 90 days
3. User must re-authenticate after expiry

### 4. Monitor Audit Logs

1. Go to https://login.tailscale.com/admin/auditlog
2. Review node additions, ACL changes, route approvals
3. Set up alerts for suspicious activity (if on paid plan)

### 5. Rotate Auth Keys Regularly

- Subnet router key: Every 180 days
- Direct node keys: Every 90 days (or use ephemeral)
- Revoke old keys immediately after rotation

---

## Advanced Configuration

### Enable Tailscale SSH

Tailscale can replace traditional SSH for easier access management:

```bash
# On each node, enable Tailscale SSH
sudo tailscale up --ssh

# Now you can SSH using Tailscale hostnames
ssh pi@pi-cm5-4.tailnet-name.ts.net

# Or using MagicDNS
ssh pi@pi-cm5-4
```

**Benefits**:
- No SSH keys to manage
- ACL-based access control
- Audit log of SSH sessions

### Use Tailscale Funnel for Public Exposure

Tailscale Funnel allows exposing services to the public internet through Tailscale:

```bash
# On K3s node, expose Jellyfin publicly
tailscale funnel 443

# Public URL: https://<node>.tailnet-name.ts.net
```

**Use case**: Temporary public access without pfSense port forwarding.

**Note**: Funnel is beta feature, verify stability before production use.

---

## Related Documentation

- [Network Topology](network-topology.md) - Overall network design
- [VLAN Configuration](vlan-configuration.md) - pfSense and Ubiquiti VLAN setup
- [Longhorn Disaster Recovery](longhorn-disaster-recovery.md) - Backup restore procedures
- [pfSense Integration Architecture](pfsense-integration-architecture.md) - Port forwarding and SSL setup

**Official Tailscale Docs**:
- Subnet routers: https://tailscale.com/kb/1019/subnets
- ACLs: https://tailscale.com/kb/1018/acls
- pfSense: https://tailscale.com/kb/1146/pfsense

---

**End of Tailscale Setup Guide**
