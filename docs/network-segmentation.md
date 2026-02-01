# Network Segmentation Guide

Step-by-step guide for configuring UniFi Cloud Gateway Fibre with VLANs and zones to isolate IoT devices from the homelab infrastructure.

## Overview

This guide implements zone-based network segmentation using UniFi's firewall. The key design decisions:

- **Zone-based firewall**: UniFi's recommended approach for policy management
- **Custom zones block all traffic by default**: Exactly what we want for IoT isolation
- **Lab devices keep existing IPs**: No changes to 192.168.1.0/24 infrastructure

## Network Structure

| Zone | Network | VLAN ID | Subnet | Purpose |
|------|---------|---------|--------|---------|
| Internal (default) | Default | 1 | 192.168.1.0/24 | Lab - keeps existing IPs |
| IoT Zone (custom) | IoT | 20 | 10.0.20.0/24 | Smart devices, TV |
| Personal Zone (custom) | Personal | 30 | 10.0.30.0/24 | Phones, tablets |

## Device Assignments

### Internal Zone (Default Network 192.168.1.0/24)

No changes required - all lab devices keep current IPs:

- pi-cm5-1, pi-cm5-2, pi-cm5-3, pi-cm5-4
- beelink, turingpi, lenovo-T14s

### IoT Zone (10.0.20.0/24)

| Device | IP | Notes |
|--------|-----|-------|
| TIZEN TV | 10.0.20.50 | Static - needs Jellyfin access |
| Xiaomi Roborock | DHCP | |
| Nintendo Switch | DHCP | |
| Sonos | DHCP | |
| Brother printer | DHCP | |

### Personal Zone (10.0.30.0/24)

| Device | IP |
|--------|-----|
| iPhone | DHCP |
| Samsung phone | DHCP |

---

## Phase 1: Create VLANs

Navigate to **Settings > Networks**

### 1.1 Create IoT Network

1. Click **Create New Network**
2. Configure:
   - **Name:** `IoT`
   - **VLAN ID:** `20`
   - **Gateway IP/Subnet:** `10.0.20.1/24`
   - **DHCP Mode:** DHCP Server
   - **DHCP Range:** `10.0.20.100` - `10.0.20.199`
   - **Isolation:** Enable "Isolate Network" (blocks IoT device-to-device)
3. Click **Create**

### 1.2 Create Personal Network

1. Click **Create New Network**
2. Configure:
   - **Name:** `Personal`
   - **VLAN ID:** `30`
   - **Gateway IP/Subnet:** `10.0.30.1/24`
   - **DHCP Mode:** DHCP Server
   - **DHCP Range:** `10.0.30.100` - `10.0.30.199`
3. Click **Create**

---

## Phase 2: Create Zones

Navigate to **Settings > Firewall & Security > Zones**

### 2.1 Enable Zone-Based Firewall

1. Go to **Settings > Firewall & Security**
2. If prompted, **Upgrade to Zone-Based Firewall** (one-time, cannot revert)
3. View default zones: Internal, External, Gateway, VPN

### 2.2 Create IoT Zone

1. Click **Create Zone**
2. Configure:
   - **Name:** `IoT Zone`
   - **Networks:** Select `IoT` network (VLAN 20)
3. Click **Create**

> **Note:** Custom zones block all traffic to other zones by default.

### 2.3 Create Personal Zone

1. Click **Create Zone**
2. Configure:
   - **Name:** `Personal Zone`
   - **Networks:** Select `Personal` network (VLAN 30)
3. Click **Create**

---

## Phase 3: Create Firewall Policies

Navigate to **Settings > Zones** or **Settings > Policy Table**

### Policy 1: Allow IoT to Gateway

Required for DHCP/DNS functionality.

1. Click **Create Policy**
2. Configure:
   - **Name:** `Allow IoT to Gateway`
   - **Source Zone:** `IoT Zone`
   - **Destination Zone:** `Gateway`
   - **Action:** `Allow`
3. Click **Create**

### Policy 2: Allow Personal to Gateway

1. Click **Create Policy**
2. Configure:
   - **Name:** `Allow Personal to Gateway`
   - **Source Zone:** `Personal Zone`
   - **Destination Zone:** `Gateway`
   - **Action:** `Allow`

### Policy 3: Allow TV to Jellyfin

1. Click **Create Policy**
2. Configure:
   - **Name:** `Allow TV to Jellyfin`
   - **Source Zone:** `IoT Zone`
   - **Source:** Create IP Group → `TV` → `10.0.20.50`
   - **Destination Zone:** `Internal`
   - **Destination:** Create IP Group → `Beelink` → `192.168.1.76`
   - **Protocol:** `TCP`
   - **Port:** `8096`
   - **Action:** `Allow`
3. Click **Create**

### Policy 4: Allow Personal to Jellyfin

1. Click **Create Policy**
2. Configure:
   - **Name:** `Allow Personal to Jellyfin`
   - **Source Zone:** `Personal Zone`
   - **Destination Zone:** `Internal`
   - **Destination:** `Beelink` IP Group (192.168.1.76)
   - **Protocol:** `TCP`
   - **Port:** `8096`
   - **Action:** `Allow`

### Policy 5: Allow Internal to IoT

Enables admin access to IoT devices.

1. Click **Create Policy**
2. Configure:
   - **Name:** `Allow Internal to IoT`
   - **Source Zone:** `Internal`
   - **Destination Zone:** `IoT Zone`
   - **Action:** `Allow`
   - **Enable:** `Auto Allow Return Traffic`

### Policy 6: Allow Internal to Personal

1. Click **Create Policy**
2. Configure:
   - **Name:** `Allow Internal to Personal`
   - **Source Zone:** `Internal`
   - **Destination Zone:** `Personal Zone`
   - **Action:** `Allow`
   - **Enable:** `Auto Allow Return Traffic`

---

## Phase 4: Configure Switch Ports

Navigate to **Devices > USW-Lite-8-PoE > Port Manager**

### Port Configuration

| Port | Primary Network | Device | Notes |
|------|-----------------|--------|-------|
| 1 | Default (All) | Uplink to UCG | Trunk - allows all VLANs |
| 2 | Default | pi-cm5-4 | Lab device |
| 3 | Default | turingpi | Lab device (has pi-cm5-1/2/3) |
| 4 | Default | beelink | Lab device |
| 5-7 | Default | (available) | Future lab devices |
| 8 | All (trunk) | Nano HD AP | Carries all VLANs to AP |

> **Important:** Keep lab device ports on "Default" network to maintain 192.168.1.x IPs.

For each port:
1. Click on the port
2. Set **Primary Network** to appropriate network
3. Click **Apply Changes**

---

## Phase 5: Create WiFi SSIDs

Navigate to **Settings > WiFi**

### 5.1 IoT WiFi

1. Click **Create New**
2. Configure:
   - **Name (SSID):** `SmartHome`
   - **Password:** (strong password)
   - **Network:** `IoT`
   - **Band:** 2.4 GHz only (IoT compatibility)
   - **Security:** WPA2 (better IoT compatibility)
3. Click **Create**

### 5.2 Personal WiFi

1. Click **Create New**
2. Configure:
   - **Name (SSID):** `Home-WiFi`
   - **Password:** (strong password)
   - **Network:** `Personal`
   - **Band:** 2.4 GHz and 5 GHz
   - **Security:** WPA3

### 5.3 Management WiFi (Optional)

1. Click **Create New**
2. Configure:
   - **Name (SSID):** `HomeLab-Mgmt`
   - **Password:** (strong password)
   - **Network:** `Default`
   - **Security:** WPA3
   - **Advanced > Hidden SSID:** Enable (optional)

---

## Phase 6: Configure WireGuard VPN

Navigate to **Settings > Teleport & VPN > VPN Server**

### 6.1 Create WireGuard Server

1. Click **Create New**
2. Configure:
   - **Type:** WireGuard
   - **Name:** `HomeLab VPN`
   - **Server Address:** `10.0.99.1/24`
   - **Listen Port:** `51820`
3. Click **Create**

### 6.2 Add VPN Client

1. Click on the WireGuard server
2. Click **Create Client**
3. Configure:
   - **Name:** `lenovo-T14s`
   - **Allowed IPs:** `10.0.99.10/32`
4. Download the configuration file or scan QR code
5. Install WireGuard on laptop and import config

### 6.3 Port Forwarding (if behind CGNAT)

If your ISP uses CGNAT, you'll need to configure port forwarding on your ISP router or use Cloudflare Tunnel as an alternative.

---

## Phase 7: Migrate Devices

### 7.1 Set Static IP for TV

1. Go to **Clients** > Find TIZEN TV
2. Click on it > **Settings**
3. Set **Fixed IP:** `10.0.20.50`
4. Click **Apply**

### 7.2 Move IoT Devices

1. Connect IoT devices to `SmartHome` WiFi
2. They will receive 10.0.20.x IPs via DHCP

### 7.3 Move Personal Devices

1. Connect phones to `Home-WiFi`
2. They will receive 10.0.30.x IPs

### 7.4 Configure TV Jellyfin App

1. Open Jellyfin app on TV
2. Set server address: `http://192.168.1.76:8096`
3. This works because of Policy 3 (Allow TV to Jellyfin)

---

## Phase 8: Enable mDNS (Optional)

For device discovery (Sonos, AirPlay, Chromecast) across VLANs:

1. Go to **Settings > Services**
2. Enable **Multicast DNS (mDNS)**
3. Select networks that need discovery

---

## Verification Checklist

After completing all phases, verify:

### Network Connectivity

- [ ] Lab devices (pi-cm5-*, beelink) retain 192.168.1.x IPs
- [ ] IoT devices receive 10.0.20.x IPs
- [ ] Personal devices receive 10.0.30.x IPs
- [ ] All devices can reach the internet

### Isolation Testing

From an IoT device (e.g., connect laptop to SmartHome WiFi):

```bash
# Should FAIL - IoT cannot reach lab
ping 192.168.1.76
curl http://192.168.1.76:8080

# Should SUCCEED - TV can reach Jellyfin (only from TV IP)
# Test from TV: open Jellyfin app
```

From a Personal device:

```bash
# Should FAIL - Personal cannot reach lab (except Jellyfin)
ping 192.168.1.76

# Should SUCCEED - Personal can reach Jellyfin
curl http://192.168.1.76:8096
```

From a Lab device:

```bash
# Should SUCCEED - Lab can reach IoT (admin access)
ping 10.0.20.50
```

### VPN Testing

1. Disconnect from home WiFi
2. Connect via WireGuard VPN
3. Verify access to 192.168.1.x devices

---

## Rollback Procedure

If issues occur, revert in reverse order:

1. **Reconnect devices to original WiFi**
2. **Delete firewall policies** (Settings > Zones)
3. **Delete custom zones** (Settings > Zones)
4. **Delete VLANs** (Settings > Networks)
5. **Reset switch ports** to Default network

---

## Troubleshooting

### Device can't get DHCP

- Verify "Allow [Zone] to Gateway" policy exists
- Check switch port is on correct network
- Verify WiFi SSID is associated with correct network

### TV can't reach Jellyfin

- Verify TV has static IP 10.0.20.50
- Check "Allow TV to Jellyfin" policy
- Verify IP groups are configured correctly
- Test: `curl http://192.168.1.76:8096` from TV

### Lab device got wrong IP

- Check switch port is set to "Default" network
- Verify device MAC isn't assigned to wrong network

### mDNS discovery not working

- Enable mDNS in Settings > Services
- Select all networks that need discovery
- Some devices may need manual IP configuration

---

## References

- [Zone-Based Firewalls in UniFi](https://help.ui.com/hc/en-us/articles/115003173168-Zone-Based-Firewalls-in-UniFi)
- [Creating Virtual Networks (VLANs)](https://help.ui.com/hc/en-us/articles/9761080275607-Creating-Virtual-Networks-VLANs)
- [UniFi Zone-Based Firewall Guide](https://lazyadmin.nl/home-network/unifi-zone-based-firewall/)
- [UniFi VLAN Configuration](https://lazyadmin.nl/home-network/unifi-vlan-configuration/)
