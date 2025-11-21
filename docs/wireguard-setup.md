# WireGuard VPN Setup Guide

**Last Updated**: 2025-11-21
**Applies To**: pfSense 2.7+, Debian-based systems
**WireGuard Version**: Native to pfSense, wireguard-tools for Linux

## Overview

This guide covers WireGuard VPN installation and configuration for secure remote access to the home lab infrastructure:
- **pfSense**: WireGuard VPN server (hub)
- **MinIO**: WireGuard peer (offsite backup target, behind NAT)
- **Clients**: Laptop and mobile devices (remote admin access)

**Goal**: Simple, native VPN for secure remote access and offsite backup connectivity without external dependencies.

---

## Prerequisites

- pfSense 2.7+ with public IP or DynDNS hostname
- MinIO server (pi-cm5-4) with Debian/Ubuntu and internet access
- Admin access to pfSense and MinIO
- Network topology documentation (for IP planning)
- No external account required (unlike Tailscale)

---

## Architecture Overview

```
                    Internet
                       ↕
                   pfSense (WireGuard Server)
                   Public IP:51820/udp
                   VPN IP: 10.99.0.1/24
                       ↕
    ┌─────────────────┼─────────────────┐
    ↓                 ↓                 ↓
MinIO (Peer)    Laptop (Peer)      Phone (Peer)
10.99.0.10      10.99.0.20         10.99.0.30
Behind NAT      Split tunnel       Split tunnel
Keepalive 25s   On-demand          On-demand
```

**Network Design:**
- **VPN Subnet**: 10.99.0.0/24
- **pfSense Endpoint**: Your public IP (or DynDNS) on UDP port 51820
- **Split Tunnel**: Clients route only home network traffic through VPN
- **MinIO Persistent Keepalive**: Maintains tunnel through NAT with 25-second heartbeat

---

## Part 1: Generate WireGuard Keys

WireGuard uses public-key cryptography. Each peer needs a keypair (private + public).

### 1.1 Generate Keys on Your Laptop

```bash
# Install WireGuard tools (for key generation)
sudo apt install wireguard-tools

# Create directory for keys
mkdir -p ~/wireguard-keys
cd ~/wireguard-keys

# Generate keypairs for all 4 peers
# pfSense server
wg genkey | tee pfsense-private.key | wg pubkey > pfsense-public.key

# MinIO peer
wg genkey | tee minio-private.key | wg pubkey > minio-public.key

# Laptop peer
wg genkey | tee laptop-private.key | wg pubkey > laptop-public.key

# Phone peer
wg genkey | tee phone-private.key | wg pubkey > phone-public.key

# Set secure permissions
chmod 600 *-private.key
chmod 644 *-public.key
```

### 1.2 View Generated Keys

```bash
# Display all keys (you'll need these during configuration)
echo "=== pfSense Server ==="
echo "Private: $(cat pfsense-private.key)"
echo "Public:  $(cat pfsense-public.key)"
echo ""
echo "=== MinIO Peer ==="
echo "Private: $(cat minio-private.key)"
echo "Public:  $(cat minio-public.key)"
echo ""
echo "=== Laptop Peer ==="
echo "Private: $(cat laptop-private.key)"
echo "Public:  $(cat laptop-public.key)"
echo ""
echo "=== Phone Peer ==="
echo "Private: $(cat phone-private.key)"
echo "Public:  $(cat phone-public.key)"
```

### 1.3 Store Keys Securely

**Store private keys in Ansible vault:**

```bash
# Move to vault directory (gitignored)
cp *-private.key ~/Prog/home-lab/vault_passwords/

# Encrypt with ansible-vault (optional, but recommended)
cd ~/Prog/home-lab
uv run ansible-vault encrypt vault_passwords/pfsense-private.key
uv run ansible-vault encrypt vault_passwords/minio-private.key
uv run ansible-vault encrypt vault_passwords/laptop-private.key
uv run ansible-vault encrypt vault_passwords/phone-private.key
```

**Keep public keys accessible** - they're not secret and needed for peer configuration.

---

## Part 2: Configure WireGuard on pfSense

### 2.1 Create WireGuard Tunnel

1. Login to pfSense WebUI: `https://192.168.92.1`
2. Navigate to **VPN → WireGuard → Tunnels**
3. Click **+ Add Tunnel**
4. Configuration:
   - **Enable**: ✅ Checked
   - **Description**: `HomeLabVPN`
   - **Listen Port**: `51820`
   - **Interface Keys**: Click **Generate** OR paste pfSense private key
     - If pasting: Use `pfsense-private.key` contents
   - **Interface Addresses**: `10.99.0.1/24`
5. Click **Save**
6. Click **Apply Changes**

**Note**: If you clicked "Generate", copy the public key shown - you'll need it for peer configs.

### 2.2 Enable WireGuard Interface

1. Navigate to **Interfaces → Assignments**
2. Find "Available network ports" dropdown
3. Select `wg0 (HomeLabVPN)` from dropdown
4. Click **+ Add**
5. Click on the new interface (e.g., "OPT1" or "WG")
6. Configuration:
   - **Enable**: ✅ Checked
   - **Description**: `WireGuard`
   - **IPv4 Configuration Type**: `None` (already configured on tunnel)
   - **IPv6 Configuration Type**: `None`
7. Click **Save**
8. Click **Apply Changes**

### 2.3 Configure Firewall Rules (WireGuard Interface)

Allow WireGuard clients to access home network:

#### Rule 1: Allow Laptop/Phone to All VLANs (Admin Access)

1. Navigate to **Firewall → Rules → WireGuard** (new tab)
2. Click **Add** (up arrow for top of list)
3. Settings:
   - **Action**: Pass
   - **Interface**: WireGuard
   - **Protocol**: Any
   - **Source**: Single host or alias → Create alias:
     - Name: `WG_Admin_Clients`
     - Type: Network(s)
     - Network: `10.99.0.20/32` (laptop), `10.99.0.30/32` (phone)
   - **Destination**: Any
   - **Description**: `Allow admin clients full access`
4. Click **Save**

#### Rule 2: Allow LAN VLAN to MinIO (Longhorn Backups)

1. Click **Add**
2. Settings:
   - **Action**: Pass
   - **Interface**: LAN
   - **Protocol**: TCP
   - **Source**: LAN net
   - **Destination**: Single host → `10.99.0.10`
   - **Destination Port**: `9000-9001`
   - **Description**: `Allow K3s to MinIO S3 API`
3. Click **Save**

#### Rule 3: Block MinIO from Initiating Connections (One-Way Security)

1. Click **Add**
2. Settings:
   - **Action**: Block
   - **Interface**: WireGuard
   - **Protocol**: Any
   - **Source**: Single host → `10.99.0.10`
   - **Destination**: Any
   - **Log**: ✅ Checked
   - **Description**: `Block MinIO outbound (one-way security)`
3. Click **Save**
4. Click **Apply Changes**

**Rule Order Verification**: Rules should be in this order:
1. Allow admin clients → Any
2. Block MinIO → Any
3. Default deny (implicit)

### 2.4 Configure WAN Firewall (Allow Inbound WireGuard)

1. Navigate to **Firewall → Rules → WAN**
2. Click **Add** (top of list)
3. Settings:
   - **Action**: Pass
   - **Interface**: WAN
   - **Protocol**: UDP
   - **Source**: Any
   - **Destination**: WAN address
   - **Destination Port**: `51820`
   - **Description**: `Allow WireGuard VPN`
4. Click **Save**
5. Click **Apply Changes**

---

## Part 3: Configure MinIO as WireGuard Peer

### 3.1 Add MinIO Peer in pfSense

1. Navigate to **VPN → WireGuard → Peers**
2. Click **+ Add Peer**
3. Configuration:
   - **Enabled**: ✅ Checked
   - **Tunnel**: `HomeLabVPN (wg0)`
   - **Description**: `MinIO Offsite`
   - **Dynamic Endpoint**: ✅ Checked (MinIO behind NAT, IP changes)
   - **Public Key**: Paste contents of `minio-public.key`
   - **Allowed IPs**: `10.99.0.10/32`
   - **Persistent Keepalive**: `25` seconds
4. Click **Save**
5. Click **Apply Changes**

**Why Persistent Keepalive?** MinIO is behind NAT. Keepalive packets every 25s keep the NAT mapping alive so pfSense can reach MinIO.

### 3.2 Install WireGuard on MinIO

SSH to MinIO server:

```bash
ssh pi@pi-cm5-4.local

# Update package list
sudo apt update

# Install WireGuard
sudo apt install -y wireguard wireguard-tools

# Verify installation
wg --version
# Expected output: wireguard-tools v1.x.x
```

### 3.3 Configure WireGuard Interface on MinIO

```bash
# Create WireGuard config directory
sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard

# Create wg0 interface config
sudo nano /etc/wireguard/wg0.conf
```

Paste the following (replace keys with your actual keys):

```ini
[Interface]
PrivateKey = <paste-minio-private-key-here>
Address = 10.99.0.10/32
DNS = 192.168.92.1

[Peer]
PublicKey = <paste-pfsense-public-key-here>
Endpoint = <your-public-ip-or-dyndns>:51820
AllowedIPs = 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24, 10.99.0.0/24
PersistentKeepalive = 25
```

**Configuration Explanation:**
- `PrivateKey`: MinIO's private key
- `Address`: MinIO's WireGuard IP
- `DNS`: pfSense DNS resolver (optional)
- `PublicKey`: pfSense's public key
- `Endpoint`: Your home public IP (or DynDNS hostname) + port 51820
- `AllowedIPs`: Routes traffic for home networks through tunnel
- `PersistentKeepalive`: Keep NAT mapping alive

```bash
# Set secure permissions
sudo chmod 600 /etc/wireguard/wg0.conf

# Test configuration syntax
sudo wg-quick up wg0

# Check status
sudo wg show

# Expected output:
# interface: wg0
#   public key: <minio-public-key>
#   private key: (hidden)
#   listening port: <random-port>
#
# peer: <pfsense-public-key>
#   endpoint: <your-public-ip>:51820
#   allowed ips: 192.168.92.0/24, ...
#   latest handshake: X seconds ago
#   transfer: X KiB received, Y KiB sent
#   persistent keepalive: every 25 seconds
```

**Success Indicator**: "latest handshake" should show recent timestamp (< 1 minute ago).

### 3.4 Enable WireGuard on Boot

```bash
# Enable systemd service
sudo systemctl enable wg-quick@wg0

# Start service
sudo systemctl start wg-quick@wg0

# Check status
sudo systemctl status wg-quick@wg0

# Expected output: "active (running)"
```

### 3.5 Test Connectivity

```bash
# From MinIO, ping pfSense WireGuard IP
ping -c 4 10.99.0.1

# Expected: Replies from 10.99.0.1

# Try to access pfSense web UI (should FAIL per firewall rules)
curl -I https://192.168.92.1 --connect-timeout 5

# Expected: Connection timeout or refused (firewall blocks MinIO → VLAN)

# Try to ping K3s node (should FAIL per firewall rules)
ping -c 2 192.168.92.11

# Expected: No route or timeout
```

**If handshake fails**, check pfSense firewall logs and verify WAN rule allows UDP 51820.

---

## Part 4: Configure Laptop Client

### 4.1 Install WireGuard on Laptop (Linux)

```bash
# Install WireGuard
sudo apt install -y wireguard

# Or on Fedora/RHEL
sudo dnf install -y wireguard-tools
```

### 4.2 Add Laptop Peer in pfSense

1. Navigate to **VPN → WireGuard → Peers**
2. Click **+ Add Peer**
3. Configuration:
   - **Enabled**: ✅ Checked
   - **Tunnel**: `HomeLabVPN (wg0)`
   - **Description**: `Laptop`
   - **Dynamic Endpoint**: ✅ Checked (laptop IP changes)
   - **Public Key**: Paste contents of `laptop-public.key`
   - **Allowed IPs**: `10.99.0.20/32`
   - **Persistent Keepalive**: Leave empty (laptop initiates connections)
4. Click **Save**
5. Click **Apply Changes**

### 4.3 Create Laptop Configuration File

```bash
# Create config directory
sudo mkdir -p /etc/wireguard
sudo chmod 700 /etc/wireguard

# Create laptop config
sudo nano /etc/wireguard/homelab.conf
```

Paste the following (replace keys and endpoint):

```ini
[Interface]
PrivateKey = <paste-laptop-private-key-here>
Address = 10.99.0.20/32
DNS = 192.168.92.1

[Peer]
PublicKey = <paste-pfsense-public-key-here>
Endpoint = <your-public-ip-or-dyndns>:51820
AllowedIPs = 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24, 10.99.0.0/24
```

**Key Difference from MinIO**: No `PersistentKeepalive` - laptop initiates connections on-demand.

```bash
# Set permissions
sudo chmod 600 /etc/wireguard/homelab.conf
```

### 4.4 Connect and Test

```bash
# Connect to VPN
sudo wg-quick up homelab

# Check status
sudo wg show

# Verify routing (only home networks routed through VPN)
ip route | grep 192.168

# Expected output:
# 192.168.0.0/24 via 10.99.0.1 dev homelab
# 192.168.10.0/24 via 10.99.0.1 dev homelab
# 192.168.92.0/24 via 10.99.0.1 dev homelab

# Test SSH to K3s node
ssh pi@192.168.92.11

# Expected: SSH prompt (full admin access)

# Test internet (should NOT go through VPN)
curl -s https://ifconfig.me

# Expected: Your laptop's public IP, NOT your home IP
```

**Success**: Split tunnel working - home network accessible, internet direct.

### 4.5 Optional: Auto-Connect on Boot

```bash
# Enable systemd service
sudo systemctl enable wg-quick@homelab

# Start service
sudo systemctl start wg-quick@homelab
```

Or use NetworkManager GUI:
1. Settings → Network → VPN → Import from file
2. Select `/etc/wireguard/homelab.conf`
3. Connect via GUI toggle

---

## Part 5: Configure Phone Client

### 5.1 Install WireGuard App

- **Android**: Install "WireGuard" from Google Play Store
- **iOS**: Install "WireGuard" from Apple App Store

### 5.2 Add Phone Peer in pfSense

1. Navigate to **VPN → WireGuard → Peers**
2. Click **+ Add Peer**
3. Configuration:
   - **Enabled**: ✅ Checked
   - **Tunnel**: `HomeLabVPN (wg0)`
   - **Description**: `Phone`
   - **Dynamic Endpoint**: ✅ Checked
   - **Public Key**: Paste contents of `phone-public.key`
   - **Allowed IPs**: `10.99.0.30/32`
   - **Persistent Keepalive**: Leave empty
4. Click **Save**
5. Click **Apply Changes**

### 5.3 Create Phone Configuration

On your laptop, create a QR code for easy phone setup:

```bash
# Create phone config file
cat > ~/wireguard-keys/phone.conf << 'EOF'
[Interface]
PrivateKey = <paste-phone-private-key-here>
Address = 10.99.0.30/32
DNS = 192.168.92.1

[Peer]
PublicKey = <paste-pfsense-public-key-here>
Endpoint = <your-public-ip-or-dyndns>:51820
AllowedIPs = 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24, 10.99.0.0/24
EOF

# Generate QR code (install qrencode if needed)
sudo apt install -y qrencode
qrencode -t ansiutf8 < ~/wireguard-keys/phone.conf
```

### 5.4 Import to Phone

1. Open WireGuard app on phone
2. Tap **+** (Add Tunnel)
3. Select **Create from QR code**
4. Scan the QR code displayed in terminal
5. Name tunnel: "HomeLab"
6. Tap **Create Tunnel**

### 5.5 Test Phone Connection

1. Toggle VPN on in WireGuard app
2. Open browser, navigate to `https://jellyfin.jardoole.xyz`
3. Verify you can access internal services
4. Check internet still works (visit any external site)

**Success**: Phone can access home services while on mobile data.

---

## Part 6: Update Longhorn Backup Target

Now that MinIO is accessible via WireGuard, update Longhorn to use WireGuard IP.

### 6.1 Test MinIO Connectivity from K3s

```bash
# SSH to any K3s node
ssh pi@192.168.92.11

# Test MinIO S3 API access via WireGuard
curl -I http://10.99.0.10:9000

# Expected: HTTP 403 or 400 (connection works, S3 auth error expected)
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

   # After (WireGuard):
   s3://longhorn-backups@us-east-1/
   http://10.99.0.10:9000
   ```
5. Click **Save**

### 6.3 Trigger Test Backup

1. In Longhorn UI, select any volume (e.g., `prowlarr-config`)
2. Click **Create Backup**
3. Wait for backup to complete (5-10 minutes depending on size)
4. Verify backup appears in MinIO:
   ```bash
   # SSH to MinIO
   ssh pi@10.99.0.10

   # List backups
   mc ls minio/longhorn-backups/
   # Should show backup files
   ```

**Success**: Longhorn now backs up to MinIO via WireGuard!

---

## Part 7: Monitoring & Maintenance

### 7.1 Check WireGuard Status

**pfSense WebUI**:
1. Navigate to **Status → WireGuard**
2. View tunnel status, peer handshakes, data transfer
3. Recent handshake = active connection

**Command Line** (pfSense shell):

```bash
# SSH to pfSense
ssh admin@192.168.92.1

# Show WireGuard status
wg show

# Expected output:
# interface: wg0
#   public key: <pfsense-public-key>
#   private key: (hidden)
#   listening port: 51820
#
# peer: <minio-public-key>
#   endpoint: <minio-public-ip>:<port>
#   allowed ips: 10.99.0.10/32
#   latest handshake: 15 seconds ago
#   transfer: 5.2 MiB received, 1.8 MiB sent
#   persistent keepalive: every 25 seconds
#
# peer: <laptop-public-key>
#   endpoint: (none)  # or recent if connected
#   allowed ips: 10.99.0.20/32
#   latest handshake: 2 hours ago
```

### 7.2 Monitor Peer Handshakes

**Healthy status indicators**:
- MinIO: "latest handshake" < 1 minute ago (due to persistent keepalive)
- Laptop/Phone: Recent handshake when connected, stale when disconnected (normal)

**Troubleshooting stale handshakes**:
```bash
# From client, try to ping pfSense WireGuard IP
ping 10.99.0.1

# If no response, check:
# 1. WAN firewall allows UDP 51820
# 2. Client config has correct endpoint
# 3. pfSense has correct public key for peer
```

### 7.3 Check Data Transfer

```bash
# On pfSense
wg show wg0 transfer

# Shows bytes sent/received per peer
# Useful for identifying active connections
```

### 7.4 View Firewall Logs

Check for blocked MinIO connection attempts:

1. Navigate to **Firewall → Logs → Firewall**
2. Filter by `WireGuard` interface
3. Look for blocked traffic from `10.99.0.10`
4. Verify one-way security is enforced

### 7.5 Performance Testing

```bash
# From laptop (connected to VPN), test throughput to home network
iperf3 -c 192.168.92.11

# Baseline WireGuard overhead
# Expected: 50-500 Mbps depending on internet speed and CPU
```

---

## Troubleshooting

### Issue: No Handshake Between pfSense and MinIO

**Symptoms**: `wg show` on pfSense shows MinIO peer but "handshake: never"

**Diagnosis**:
```bash
# Check pfSense WAN firewall logs
# Firewall → Logs → Firewall
# Look for blocks on UDP 51820

# On MinIO, check wg status
sudo wg show

# Check if MinIO can reach pfSense public IP
ping <your-public-ip>

# Check if UDP 51820 is reachable
nc -vuz <your-public-ip> 51820
```

**Common Causes**:
1. **WAN firewall blocking**: Add rule to allow UDP 51820 (see Part 2.4)
2. **Wrong endpoint**: Verify `Endpoint` in MinIO config matches your public IP/DynDNS
3. **Key mismatch**: Verify public keys match in both configs
4. **ISP blocking UDP**: Some ISPs block non-standard UDP ports (rare)

**Solution**:
```bash
# Restart WireGuard on MinIO
sudo systemctl restart wg-quick@wg0

# Check logs
sudo journalctl -u wg-quick@wg0 -n 50

# Force handshake attempt
sudo wg set wg0 peer <pfsense-public-key> endpoint <your-public-ip>:51820
```

---

### Issue: Laptop Can Connect But Cannot Access Home Network

**Symptoms**: Handshake succeeds, but `ping 192.168.92.11` times out

**Diagnosis**:
```bash
# From laptop
sudo wg show

# Verify AllowedIPs includes home networks
# Should show: allowed ips: 192.168.92.0/24, 192.168.0.0/24, ...

# Check routing table
ip route | grep 192.168

# Should show routes via wg interface
```

**Common Causes**:
1. **pfSense firewall blocks**: Check WireGuard interface rules (Part 2.3)
2. **Wrong AllowedIPs**: Verify laptop config includes `192.168.92.0/24`
3. **NAT issues**: Verify pfSense has outbound NAT for WireGuard interface

**Solution**:
```bash
# Verify pfSense WireGuard interface has correct firewall rules
# Should allow laptop IP (10.99.0.20) to access LAN net

# Check outbound NAT (should be automatic)
# Firewall → NAT → Outbound
# Verify WireGuard interface is included in automatic NAT
```

---

### Issue: MinIO Can Initiate Connections to Home Network

**Symptoms**: MinIO can ping 192.168.92.11 (should be blocked)

**Diagnosis**:
```bash
# From MinIO
ping 192.168.92.11

# If succeeds, firewall rule is missing or misconfigured
```

**Solution**:
1. Navigate to **Firewall → Rules → WireGuard**
2. Verify block rule exists: Source = `10.99.0.10`, Destination = Any
3. Ensure block rule comes BEFORE any allow rules
4. Check rule is enabled
5. Click **Apply Changes**

---

### Issue: Split Tunnel Not Working (All Traffic Goes Through VPN)

**Symptoms**: `curl https://ifconfig.me` shows home public IP instead of laptop's IP

**Diagnosis**:
```bash
# Check routing table
ip route

# Look for default route
# Should show: default via <local-gateway> dev <local-interface>
# NOT: default via 10.99.0.1 dev homelab
```

**Common Cause**: `AllowedIPs = 0.0.0.0/0` in client config (full tunnel)

**Solution**:
```bash
# Edit laptop config
sudo nano /etc/wireguard/homelab.conf

# Ensure AllowedIPs does NOT include 0.0.0.0/0
# Should be:
AllowedIPs = 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24, 10.99.0.0/24

# Restart connection
sudo wg-quick down homelab
sudo wg-quick up homelab
```

---

### Issue: Persistent Keepalive Not Working for MinIO

**Symptoms**: MinIO handshake goes stale, pfSense cannot reach MinIO

**Diagnosis**:
```bash
# On MinIO, check wg config
sudo cat /etc/wireguard/wg0.conf | grep PersistentKeepalive

# Should show: PersistentKeepalive = 25

# Check wg status
sudo wg show | grep persistent

# Should show: persistent keepalive: every 25 seconds
```

**Solution**:
```bash
# Add persistent keepalive to config
sudo nano /etc/wireguard/wg0.conf

# Under [Peer] section, add:
PersistentKeepalive = 25

# Restart WireGuard
sudo systemctl restart wg-quick@wg0

# Verify in status
sudo wg show
```

---

## Security Best Practices

### 1. Rotate Keys Periodically

```bash
# Generate new keypairs every 6-12 months
wg genkey | tee new-private.key | wg pubkey > new-public.key

# Update peer configs with new keys
# Restart WireGuard services
```

### 2. Limit Peer Access with Firewall Rules

Never rely solely on `AllowedIPs` for access control. Use pfSense firewall rules:
- Admin clients: Full access
- MinIO: One-way only (blocked from initiating)
- IoT devices: NOT on WireGuard (stay on IoT VLAN)

### 3. Monitor Firewall Logs

```bash
# Check for unauthorized access attempts
# Firewall → Logs → Firewall
# Filter by WireGuard interface
# Look for blocked traffic
```

### 4. Use Strong Private Keys

WireGuard generates cryptographically secure keys by default. Never:
- Share private keys between peers
- Store private keys unencrypted in public repos
- Use weak key generation methods

### 5. Secure MinIO Endpoint

MinIO has no public exposure - only accessible via:
1. WireGuard VPN (authenticated clients only)
2. One-way from home network (for backups)

Verify with port scan from internet:
```bash
# From external network (mobile data)
nmap -p 9000,9001 <minio-public-ip>

# Expected: Ports closed/filtered
```

---

## Advanced Configuration

### Option 1: Dynamic DNS for pfSense Endpoint

If your home public IP changes frequently:

1. Set up DynDNS service (e.g., Cloudflare, DuckDNS)
2. In pfSense: **Services → Dynamic DNS → Add**
3. Configure DynDNS client
4. Update all peer configs:
   ```ini
   Endpoint = yourname.duckdns.org:51820
   ```

### Option 2: Multiple WireGuard Tunnels

Separate tunnels for different purposes:
- Tunnel 1 (wg0): Admin access (laptop, phone)
- Tunnel 2 (wg1): Guest access (limited)
- Tunnel 3 (wg2): Site-to-site (MinIO only)

Each tunnel has independent firewall rules and IP range.

### Option 3: WireGuard on Multiple Ports

For restrictive networks that block UDP 51820:
1. Create additional tunnel on port 443 (UDP)
2. Update WAN firewall to allow both
3. Use alternative endpoint when needed

---

## Related Documentation

- [Network Topology](network-topology.md) - Overall network design with WireGuard
- [VLAN Configuration](vlan-configuration.md) - pfSense and Ubiquiti VLAN setup
- [Longhorn Disaster Recovery](longhorn-disaster-recovery.md) - Backup restore procedures
- [pfSense Integration Architecture](pfsense-integration-architecture.md) - Port forwarding and SSL setup

**Official WireGuard Docs**:
- Quick Start: https://www.wireguard.com/quickstart/
- pfSense Integration: https://docs.netgate.com/pfsense/en/latest/vpn/wireguard/index.html
- Protocol Details: https://www.wireguard.com/protocol/

---

**End of WireGuard Setup Guide**
