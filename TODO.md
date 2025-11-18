# TODO - Home Lab Tasks

**Last Updated**: 2025-11-18

---

## Current Projects

### ✅ Completed: Media Stack Deployment

**Status**: COMPLETE - All apps running and configured

- 6 apps running (Jellyfin, Jellyseerr, Radarr, Sonarr, Prowlarr, qBittorrent)
- All UI configuration complete
- Intel QuickSync hardware transcoding enabled
- API integrations working
- End-to-end workflow tested (request → download → playback)
- Hardlinks verified for storage efficiency

**Documentation**: See `docs/media-stack-complete-guide.md`

### 🔄 In Progress: Network Migration Project

**Goal**: Multi-VLAN Network Segmentation + Tailscale Remote Access

**Current State**: All devices on single flat network (192.168.0.0/24)
- ❌ No network segmentation (IoT can access servers)
- ❌ No remote access (cannot manage cluster from outside)
- ❌ MinIO on local network (physical theft risk)

**Target State**: Multi-VLAN with Tailscale overlay
- ✅ Network segmentation (LAN, IoT, Guest VLANs)
- ✅ Secure remote access (Tailscale for laptop/mobile)
- ✅ Offsite MinIO backup (physically separate, Tailscale-connected)
- ✅ IoT isolation (can watch Jellyfin, cannot SSH to servers)

**Documentation**: See `docs/network-topology.md` and `docs/tailscale-setup.md`

**Why This Matters**: See [docs/network-topology.md#current-issues](docs/network-topology.md#current-issues)

---

## Quick Reference

### Media Stack Access URLs (HTTPS)

- **Jellyfin**: <https://jellyfin.jardoole.xyz> (streaming)
- **Jellyseerr**: <https://jellyseerr.jardoole.xyz> (requests)
- **Radarr**: <https://radarr.jardoole.xyz> (movies)
- **Sonarr**: <https://sonarr.jardoole.xyz> (TV)
- **Prowlarr**: <https://prowlarr.jardoole.xyz> (indexers)
- **qBittorrent**: <https://qbittorrent.jardoole.xyz> (downloads)
- **Longhorn**: <https://longhorn.jardoole.xyz> (storage/backups)

### Useful Commands

```bash
# Pod status
kubectl get pods -n media

# Resource usage
kubectl top pods -n media

# App logs
kubectl logs -n media deployment/{app} --tail=100 -f

# Restart app
kubectl rollout restart deployment/{app} -n media
```

### Key Documentation

- **Media Stack**: `docs/media-stack-complete-guide.md` (full setup, architecture, troubleshooting)
- **Network Topology**: `docs/network-topology.md` (network architecture and migration plan)
- **Tailscale Setup**: `docs/tailscale-setup.md` (remote access configuration)
- **App Deployment**: `docs/app-deployment-guide.md` (Helm chart deployment pattern)
- **Project Structure**: `docs/project-structure.md` (architecture overview)
- **Git Commits**: `docs/git-commit-guidelines.md` (commit message standards)

---

## Prerequisite Tasks (Before Network Migration)

### ⚠️ CRITICAL: Backup Testing (From Media Stack)

**Status**: ⚠️ **NOT YET TESTED - MUST COMPLETE BEFORE NETWORK CHANGES**

**Why**: Backups are worthless if you can't restore. Test BEFORE risking network changes.

- [ ] **Test Individual PVC Restore** (~15 min)
  - **Why**: Verify Longhorn backups actually work before risking network changes
  - **How**:
    ```bash
    # Step 1: Take manual backup
    # Longhorn UI → Volumes → prowlarr-config → Create Backup

    # Step 2: Delete PVC
    kubectl delete pvc prowlarr-config -n media

    # Step 3: Restore from backup
    # Longhorn UI → Backup → Select backup → Restore (name: prowlarr-config)

    # Step 4: Redeploy app
    make app-deploy APP=prowlarr

    # Step 5: Verify all settings intact
    # Open: https://prowlarr.jardoole.xyz
    # Check: Indexers, API keys, app connections all present
    ```
  - **Expected**: Full restore in < 10 minutes, zero config loss

- [ ] **Document Cluster State Snapshot**
  - **Why**: Baseline snapshot for disaster recovery
  - **How**:
    ```bash
    kubectl get pvc --all-namespaces > cluster-state-$(date +%Y%m%d).txt
    kubectl get deployments --all-namespaces >> cluster-state-$(date +%Y%m%d).txt
    helm list --all-namespaces >> cluster-state-$(date +%Y%m%d).txt

    # Note Longhorn S3 settings
    # Longhorn UI → Setting → Backup Target (record S3 URL and bucket)
    ```
  - **Save**: vault_passwords/ directory (gitignored)

- [ ] **Verify Longhorn Backup Schedule Active**
  - **Why**: Ensure automated backups running before migration
  - **How**: Longhorn UI → Settings → Recurring Jobs → Verify schedules
  - **Expected**: Daily backups at 2 AM, weekly backups Sunday 3 AM

### Optional Enhancement Tasks (Media Stack)

**Status**: 📋 **NOT URGENT - Do After Network Migration**

- [ ] **Deploy Bazarr** (subtitle automation)
  - Only if multilingual subtitles needed
  - Same bjw-s/app-template pattern
  - Connects to Radarr/Sonarr

- [ ] **Add Music Library** (Lidarr + Navidrome)
  - Lidarr: Music automation (like Radarr for music)
  - Navidrome: Music streaming server

- [ ] **Configure Notifications**
  - Jellyseerr → Discord/Telegram: New requests
  - Radarr/Sonarr → Discord: Download completion
  - Jellyfin → Email: New content available

- [ ] **Implement Request Quotas**
  - Jellyseerr → Settings → Users → Limits
  - Prevent abuse (e.g., 10 movies/week per user)

---

# Network Migration Phases

## Phase 0: Documentation Completion

**Status**: 🔄 **IN PROGRESS**

**Goal**: Complete all documentation before touching hardware.

**Why**: Having complete docs BEFORE network changes means you can follow step-by-step instructions under pressure. See "Prerequisite Tasks" section above - backup testing must be complete before starting Phase 1.

### Tasks

**NOTE**: The critical backup testing tasks are listed in "Prerequisite Tasks (Before Network Migration)" section above. Complete those FIRST.

---

## Phase 1: Documentation & Planning

**Status**: 🔄 **IN PROGRESS**

**Goal**: Create missing documentation guides before touching hardware.

**Why**: Having complete docs BEFORE making changes means you can follow step-by-step instructions under pressure (e.g., at 2am when something breaks). No guessing, no improvising.

See: [docs/network-topology.md#implementation-phases](docs/network-topology.md#implementation-phases)

### Tasks

- [x] **Create Network Topology Documentation**
  - ✅ Current and target architecture diagrams
  - ✅ IP address allocation tables
  - ✅ Firewall rules specifications

- [x] **Create Tailscale Setup Guide**
  - ✅ pfSense subnet router configuration
  - ✅ MinIO direct node setup
  - ✅ ACL policy examples

- [ ] **Create VLAN Configuration Guide**
  - **Why**: Step-by-step pfSense + Ubiquiti VLAN setup prevents mistakes
  - **Content**:
    - pfSense VLAN interface creation (VLANs 1, 10, 20)
    - DHCP server configuration per VLAN
    - Switch port-based VLAN assignment
    - AP multi-SSID to VLAN mapping
  - **File**: `docs/vlan-configuration.md`
  - **Reference**: [docs/network-topology.md#phase-2-vlan-configuration](docs/network-topology.md#phase-2-vlan-configuration)

- [ ] **Create UniFi Controller Deployment Guide**
  - **Why**: Need UniFi Controller to manage AP multi-SSID and switch VLANs
  - **Content**:
    - Helm chart deployment on K3s
    - Initial setup wizard walkthrough
    - Switch adoption procedure
    - AP adoption procedure
    - Backup/restore configuration
  - **File**: `docs/unifi-controller-deployment.md`
  - **Reference**: [docs/network-topology.md#phase-1-testing--preparation](docs/network-topology.md#phase-1-testing--preparation)

- [ ] **Update pfSense Integration Docs**
  - **Why**: Existing docs need Tailscale section and port forwarding updates
  - **Changes**:
    - Add Tailscale subnet router section
    - Update HAProxy references to port forwarding (if any)
    - Document WAN:443 → K3s:11443 configuration
  - **File**: `docs/pfsense-integration-architecture.md`

- [ ] **Update Project Structure Docs**
  - **Why**: Document new network architecture in overview
  - **Changes**:
    - Add network architecture section
    - Document VLAN structure
    - Link to network topology docs
  - **File**: `docs/project-structure.md`

- [ ] **Create Network Variables in group_vars**
  - **Why**: Centralize IP addresses for Ansible playbooks
  - **Content**:
    ```yaml
    # group_vars/all/network.yml
    lan_vlan_subnet: "192.168.92.0/24"
    lan_vlan_gateway: "192.168.92.1"
    iot_vlan_subnet: "192.168.0.0/24"
    iot_vlan_gateway: "192.168.0.1"
    guest_vlan_subnet: "192.168.10.0/24"
    guest_vlan_gateway: "192.168.10.1"
    ```
  - **Files**:
    - `group_vars/all/network.yml` (plain)
    - `group_vars/all/vault.yml` (Tailscale auth keys)

---

## Phase 2: Tailscale Account Setup

**Status**: 📋 **READY TO START**

**Goal**: Create Tailscale account and pre-auth keys before installing anything.

**Why**: Doing admin tasks (account creation, key generation) BEFORE installation means you can complete installation without interruptions. Keys will be ready to paste during setup.

**Time Estimate**: 30 minutes

See: [docs/tailscale-setup.md#part-1-tailscale-account-setup](docs/tailscale-setup.md#part-1-tailscale-account-setup)

### Tasks

- [ ] **Create Tailscale Account**
  - **Why**: Free tier supports 100 devices (you need ~7)
  - **How**: Visit https://login.tailscale.com/start
  - **Verify**: Account created, email verified

- [ ] **Enable MagicDNS**
  - **Why**: Automatic DNS names (e.g., `pi-cm5-1.tailnet-name.ts.net`)
  - **How**: Admin Console → DNS → Enable MagicDNS
  - **Test**: Confirm enabled in Tailscale admin console

- [ ] **Generate Subnet Router Pre-Auth Key**
  - **Why**: pfSense non-interactive installation
  - **Settings**:
    - Reusable: ✅ Yes (pfSense reinstall safety)
    - Ephemeral: ❌ No (persistent node)
    - Pre-approved: ✅ Yes (auto-approve routes)
    - Tags: `tag:subnet-router`
  - **Save**: `vault_passwords/tailscale-subnet-key.txt` (gitignored)
  - **Reference**: [docs/tailscale-setup.md#subnet-router-key-pfsense](docs/tailscale-setup.md#subnet-router-key-pfsense)

- [ ] **Generate MinIO Direct Node Pre-Auth Key**
  - **Why**: MinIO non-interactive installation when offsite
  - **Settings**:
    - Reusable: ❌ No (single-use security)
    - Ephemeral: ❌ No (persistent node)
    - Pre-approved: ✅ Yes
    - Tags: `tag:offsite-nas`
  - **Save**: `vault_passwords/tailscale-minio-key.txt` (gitignored)
  - **Reference**: [docs/tailscale-setup.md#minio-direct-node-key](docs/tailscale-setup.md#minio-direct-node-key)

- [ ] **Draft Tailscale ACL Policy**
  - **Why**: Have ACLs ready before connecting nodes (deny-by-default)
  - **Content**: Copy from [docs/tailscale-setup.md#41-edit-acl-policy](docs/tailscale-setup.md#41-edit-acl-policy)
  - **Important**: Replace `user@example.com` with your email
  - **Save**: Locally as `tailscale-acl-draft.json` (apply later)

---

## Phase 3: UniFi Controller Deployment

**Status**: 📋 **READY AFTER PHASE 1 DOCS**

**Goal**: Deploy UniFi Controller on K3s to manage switch and AP.

**Why**: UniFi Controller is required to configure multi-SSID WiFi and VLAN tagging on switch/AP. Must be deployed BEFORE touching hardware so you can manage it remotely if something breaks.

**Time Estimate**: 1 hour

See: [docs/network-topology.md#phase-1-testing--preparation](docs/network-topology.md#phase-1-testing--preparation)

### Tasks

- [ ] **Create UniFi Controller Helm Chart**
  - **Why**: Standardized deployment like other apps
  - **Directory**: `apps/unifi-controller/`
  - **Files**:
    - `Chart.yml` (chart metadata)
    - `values.yml` (Helm values with ingress, persistence)
    - `app.yml` (playbook importing deploy-helm-app.yml)
    - `README.md` (access instructions)
  - **Reference**: Follow pattern from `apps/jellyfin/` structure
  - **PVC**: 10Gi Longhorn storage for UniFi database

- [ ] **Deploy UniFi Controller**
  - **How**: `make app-deploy APP=unifi-controller`
  - **Verify**: Pod running: `kubectl get pods -n network`

- [ ] **Access UniFi Controller Setup Wizard**
  - **URL**: https://unifi.jardoole.xyz
  - **Steps**:
    1. Create admin account
    2. Skip auto-detection (manual adoption)
    3. Configure site name: "Home Lab"
  - **Document**: Save admin credentials to vault_passwords/

- [ ] **Configure UniFi Controller Backup**
  - **Why**: UniFi config is critical - must be backed up
  - **How**: Settings → Maintenance → Backup → Enable auto-backup
  - **Verify**: Backups stored in PVC (backed up by Longhorn)

---

## Phase 4: Hardware Inventory & Access Prep

**Status**: 📋 **READY AFTER PHASE 3**

**Goal**: Ensure physical access to pfSense and document current state before changes.

**Why**: Network changes can lock you out remotely. Having physical access (keyboard/monitor) to pfSense means you can always recover from mistakes.

**Time Estimate**: 30 minutes

### Tasks

- [ ] **Setup pfSense Console Access**
  - **Why**: If remote access breaks, you need console
  - **How**: Connect keyboard + monitor to pfSense box
  - **Test**: Boot pfSense, verify console works, test option 8 (shell access)

- [ ] **Document Current pfSense Config**
  - **Why**: Rollback capability if VLAN config goes wrong
  - **How**: pfSense UI → Diagnostics → Backup & Restore → Download Configuration
  - **Save**: `backups/pfsense-config-pre-vlan-$(date +%Y%m%d).xml`
  - **Location**: vault_passwords/ (gitignored)

- [ ] **Document Current Switch/AP State**
  - **Why**: Baseline configuration before VLAN changes
  - **How**:
    - Take screenshots of switch port config in UniFi Controller
    - Document current IPs: switch (192.168.0.2), AP (192.168.0.3)
  - **Save**: Notes in TODO.md or local file

- [ ] **Verify Physical Access to All Hardware**
  - **Check**:
    - ✅ Can reach pfSense physically
    - ✅ Can access switch via UniFi Controller
    - ✅ Can access AP via UniFi Controller
    - ✅ Turing Pi / Beelink have network connectivity
  - **Why**: If something breaks, you need physical access to fix it

---

## Phase 5: Adopt Switch & AP to UniFi Controller

**Status**: 📋 **READY AFTER PHASE 4**

**Goal**: Bring switch and AP under UniFi Controller management.

**Why**: Controller adoption BEFORE VLAN changes means you can manage switch/AP remotely. If adoption fails after VLANs configured, you'd be locked out.

**Time Estimate**: 1 hour

See: UniFi Controller deployment guide (to be created)

### Tasks

- [ ] **Factory Reset Switch (if previously managed)**
  - **Why**: Clean slate ensures no config conflicts
  - **How**: Physical reset button on switch (hold 10+ seconds until LEDs flash)
  - **Wait**: 5 minutes for switch to reboot

- [ ] **Adopt Switch via UniFi Controller**
  - **How**:
    1. UniFi Controller → Devices → Scan for devices
    2. Find switch (192.168.0.2) → Click Adopt
    3. Wait 5-10 minutes for adoption + firmware update
  - **Verify**: Switch shows "Connected" in UniFi Controller
  - **Test**: Can view switch port status in Controller UI

- [ ] **Adopt AP via UniFi Controller**
  - **How**:
    1. UniFi Controller → Devices → Scan for devices
    2. Find AP (192.168.0.3) → Click Adopt
    3. Wait 10-15 minutes for adoption + firmware update
  - **Verify**: AP shows "Connected" in UniFi Controller
  - **Test**: Current WiFi still working

- [ ] **Configure Switch Static IP**
  - **Why**: Prevent IP change during DHCP migration
  - **How**: UniFi Controller → Devices → Switch → Config → Static IP: 192.168.0.2
  - **Verify**: Switch reachable at 192.168.0.2

- [ ] **Configure AP Static IP**
  - **Why**: Prevent IP change during DHCP migration
  - **How**: UniFi Controller → Devices → AP → Config → Static IP: 192.168.0.3
  - **Verify**: AP reachable at 192.168.0.3

- [ ] **Backup UniFi Controller Config**
  - **Why**: Save clean adopted state before VLAN changes
  - **How**: Settings → Maintenance → Backup → Download
  - **Save**: `backups/unifi-config-adopted-$(date +%Y%m%d).unf`

---

## Phase 6: VLAN Configuration (pfSense)

**Status**: 📋 **READY AFTER PHASE 5**

**Goal**: Create three VLANs in pfSense with DHCP servers.

**Why**: VLANs must exist in pfSense BEFORE configuring switch, otherwise switch won't know where to send tagged traffic.

**Time Estimate**: 2 hours

**⚠️ RISK**: High - can break network connectivity. Have physical console access ready.

See: [docs/network-topology.md#phase-2-vlan-configuration](docs/network-topology.md#phase-2-vlan-configuration)

### Tasks

- [ ] **Create LAN VLAN Interface (VLAN 1)**
  - **Why**: Primary network for servers and admin devices
  - **How**: pfSense → Interfaces → Assignments → VLANs → Add
    - Parent Interface: LAN (existing)
    - VLAN Tag: 1
    - Description: "LAN VLAN"
  - **Verify**: VLAN 1 appears in VLAN list

- [ ] **Configure LAN VLAN Interface**
  - **How**: Interfaces → OPT1 (or new interface) → Enable
    - IPv4 Configuration: Static
    - IPv4 Address: 192.168.92.1/24
    - Description: "LAN"
  - **Verify**: Can ping 192.168.92.1 from pfSense shell

- [ ] **Configure LAN VLAN DHCP Server**
  - **Why**: Dynamic IPs for laptops/admin devices
  - **How**: Services → DHCP Server → LAN
    - Enable: ✅ Yes
    - Range: 192.168.92.100 - 192.168.92.200
    - DNS Servers: 1.1.1.1, 8.8.8.8
    - Gateway: 192.168.92.1
  - **Verify**: DHCP server enabled for LAN VLAN

- [ ] **Create IoT VLAN Interface (VLAN 10)**
  - **Why**: Isolated network for IoT devices (keep current subnet)
  - **How**: pfSense → Interfaces → Assignments → VLANs → Add
    - Parent Interface: LAN
    - VLAN Tag: 10
    - Description: "IoT VLAN"

- [ ] **Configure IoT VLAN Interface**
  - **How**: Interfaces → OPT2 → Enable
    - IPv4 Configuration: Static
    - IPv4 Address: 192.168.0.1/24
    - Description: "IoT"

- [ ] **Configure IoT VLAN DHCP Server**
  - **How**: Services → DHCP Server → IoT
    - Enable: ✅ Yes
    - Range: 192.168.0.100 - 192.168.0.250
    - DNS Servers: 1.1.1.1, 8.8.8.8
    - Gateway: 192.168.0.1

- [ ] **Create Guest VLAN Interface (VLAN 20)**
  - **Why**: Isolated network for guest devices
  - **How**: pfSense → Interfaces → Assignments → VLANs → Add
    - Parent Interface: LAN
    - VLAN Tag: 20
    - Description: "Guest VLAN"

- [ ] **Configure Guest VLAN Interface**
  - **How**: Interfaces → OPT3 → Enable
    - IPv4 Configuration: Static
    - IPv4 Address: 192.168.10.1/24
    - Description: "Guest"

- [ ] **Configure Guest VLAN DHCP Server**
  - **How**: Services → DHCP Server → Guest
    - Enable: ✅ Yes
    - Range: 192.168.10.100 - 192.168.10.250
    - DNS Servers: 1.1.1.1, 8.8.8.8
    - Gateway: 192.168.10.1

- [ ] **Verify VLAN Routing**
  - **How**: pfSense shell → `ping 192.168.92.1`, `ping 192.168.0.1`, `ping 192.168.10.1`
  - **Expected**: All three gateways reachable from pfSense

---

## Phase 7: Update K3s Node Static IPs

**Status**: 📋 **READY AFTER PHASE 6**

**Goal**: Assign new static IPs to K3s nodes in LAN VLAN range.

**Why**: K3s nodes must have static IPs in LAN VLAN (192.168.92.x) before switch VLAN cutover. Doing this NOW while old network still works prevents IP conflicts.

**Time Estimate**: 1 hour

**⚠️ IMPORTANT**: This changes IPs while still on old network. Services will be briefly unreachable.

### Tasks

- [ ] **Update pi-cm5-1 Static IP: 192.168.0.11 → 192.168.92.11**
  - **Why**: New IP in LAN VLAN range
  - **How**:
    ```bash
    ssh pi@pi-cm5-1.local
    sudo nano /etc/netplan/50-cloud-init.yaml
    # Change: addresses: [192.168.0.11/24] → [192.168.92.11/24]
    # Change: gateway4: 192.168.0.1 → 192.168.92.1
    sudo netplan apply
    ```
  - **Verify**: `ip addr` shows 192.168.92.11
  - **Test**: Can still SSH via new IP: `ssh pi@192.168.92.11`

- [ ] **Update pi-cm5-2 Static IP: 192.168.0.12 → 192.168.92.12**
  - **How**: Same as pi-cm5-1
  - **Verify**: `ssh pi@192.168.92.12` works

- [ ] **Update pi-cm5-3 Static IP: 192.168.0.13 → 192.168.92.13**
  - **How**: Same as pi-cm5-1
  - **Verify**: `ssh pi@192.168.92.13` works

- [ ] **Update beelink Static IP: 192.168.0.14 → 192.168.92.14**
  - **How**: Same as pi-cm5-1
  - **Verify**: `ssh user@192.168.92.14` works

- [ ] **Verify K3s Cluster Connectivity**
  - **Why**: Ensure K3s cluster still communicating after IP changes
  - **How**: `kubectl get nodes` from any control plane node
  - **Expected**: All 4 nodes show "Ready"

- [ ] **Verify Service Access**
  - **Test**: Access https://jellyfin.jardoole.xyz
  - **Expected**: All apps still accessible

- [ ] **Update Ansible Inventory**
  - **Why**: Reflect new IPs for future playbooks
  - **How**: Edit `hosts.ini`
    ```ini
    [control_plane]
    pi-cm5-1 ansible_host=192.168.92.11
    pi-cm5-2 ansible_host=192.168.92.12
    pi-cm5-3 ansible_host=192.168.92.13

    [workers]
    beelink ansible_host=192.168.92.14
    ```
  - **Test**: `ansible all -m ping`

---

## Phase 8: Switch VLAN Configuration

**Status**: 📋 **READY AFTER PHASE 7**

**Goal**: Configure port-based VLANs on Ubiquiti Switch.

**Why**: Switch must tag traffic to correct VLANs so pfSense can route properly. Port 6 (AP uplink) is trunk carrying all VLANs, other ports are access ports.

**Time Estimate**: 1 hour

**⚠️ RISK**: High - wrong config can disconnect switch. Have physical access ready.

See: [docs/network-topology.md#switch-port-configuration](docs/network-topology.md#switch-port-configuration)

### Tasks

- [ ] **Create VLAN Networks in UniFi Controller**
  - **Why**: Controller must know about VLANs before assigning to ports
  - **How**: Settings → Networks → Create New Network
    - **LAN VLAN**:
      - Name: "LAN"
      - VLAN ID: 1
      - Gateway/Subnet: 192.168.92.1/24
    - **IoT VLAN**:
      - Name: "IoT"
      - VLAN ID: 10
      - Gateway/Subnet: 192.168.0.1/24
    - **Guest VLAN**:
      - Name: "Guest"
      - VLAN ID: 20
      - Gateway/Subnet: 192.168.10.1/24
  - **Verify**: Three VLAN networks visible in controller

- [ ] **Configure Port 1 (Uplink to pfSense): Trunk**
  - **Why**: Carries all VLAN traffic to pfSense
  - **How**: Devices → Switch → Ports → Port 1
    - Port Profile: "All" (trunk mode)
    - Native VLAN: LAN (VLAN 1)
    - Tagged VLANs: LAN (1), IoT (10), Guest (20)
  - **Verify**: Port 1 shows "All" profile

- [ ] **Configure Ports 2-5 (Turing Pi, Beelink): Access Mode LAN VLAN**
  - **Why**: K3s nodes on LAN VLAN
  - **How**: Devices → Switch → Ports → Select Ports 2-5
    - Port Profile: "LAN" (access mode)
    - VLAN: LAN (1)
  - **Verify**: Ports show "LAN" profile

- [ ] **Configure Port 6 (AP Uplink): Trunk**
  - **Why**: AP needs all VLANs for multi-SSID
  - **How**: Devices → Switch → Ports → Port 6
    - Port Profile: "All" (trunk mode)
    - Native VLAN: LAN (VLAN 1)
    - Tagged VLANs: LAN (1), IoT (10), Guest (20)
  - **Verify**: Port 6 shows "All" profile

- [ ] **Apply Switch Configuration**
  - **How**: Review changes → Apply
  - **Wait**: 2 minutes for switch provisioning

- [ ] **Verify K3s Cluster Connectivity After Switch Changes**
  - **How**: `kubectl get nodes`
  - **Expected**: All 4 nodes "Ready"
  - **If broken**: Physical console to pfSense → revert switch config in UniFi Controller

- [ ] **Verify Current WiFi Still Works**
  - **Test**: Connect laptop to existing WiFi SSID
  - **Expected**: Internet still works (currently untagged traffic)

---

## Phase 9: Multi-SSID WiFi Configuration

**Status**: 📋 **READY AFTER PHASE 8**

**Goal**: Create three SSIDs mapped to three VLANs.

**Why**: Separates trusted devices (HomeNetwork/LAN), IoT devices (SmartHome/IoT), and guests (Guest/Guest). Makes it easy to move devices to correct networks.

**Time Estimate**: 1 hour

See: [docs/network-topology.md#phase-3-multi-ssid-wifi](docs/network-topology.md#phase-3-multi-ssid-wifi)

### Tasks

- [ ] **Create "HomeNetwork" SSID → LAN VLAN**
  - **Why**: Trusted devices (laptop, phone) on secure network
  - **How**: Settings → WiFi → Create New Network
    - Name: "HomeNetwork"
    - Security: WPA3-Personal (or WPA2/3 mixed)
    - Password: (strong password)
    - Network: LAN (VLAN 1)
  - **Verify**: SSID appears in available networks

- [ ] **Create "SmartHome" SSID → IoT VLAN**
  - **Why**: IoT devices on isolated network
  - **How**: Settings → WiFi → Create New Network
    - Name: "SmartHome"
    - Security: WPA2-Personal (IoT device compatibility)
    - Password: (strong password)
    - Network: IoT (VLAN 10)
  - **Verify**: SSID appears in available networks

- [ ] **Create "Guest" SSID → Guest VLAN**
  - **Why**: Visitors on completely isolated network
  - **How**: Settings → WiFi → Create New Network
    - Name: "Guest"
    - Security: WPA2-Personal
    - Password: (simple guest password)
    - Network: Guest (VLAN 20)
    - Guest Policy: ✅ Enable (isolate clients)
  - **Verify**: SSID appears in available networks

- [ ] **Test Laptop on HomeNetwork SSID**
  - **How**: Connect laptop to "HomeNetwork" SSID
  - **Verify**:
    - Gets 192.168.92.x IP (DHCP)
    - Can access internet
    - Can SSH to K3s nodes: `ssh pi@192.168.92.11`
    - Can access apps: https://jellyfin.jardoole.xyz

- [ ] **Test IoT Device on SmartHome SSID**
  - **How**: Connect smart device to "SmartHome" SSID
  - **Verify**:
    - Gets 192.168.0.x IP (DHCP)
    - Can access internet
    - Can access Jellyfin: https://jellyfin.jardoole.xyz

- [ ] **Test Guest Device on Guest SSID**
  - **How**: Connect guest phone to "Guest" SSID
  - **Verify**:
    - Gets 192.168.10.x IP (DHCP)
    - Can access internet
    - **Cannot** access https://jellyfin.jardoole.xyz (no route yet)

- [ ] **Migrate All Devices to Correct SSIDs**
  - **Why**: Move devices off old network before disabling it
  - **How**:
    - Reconnect laptop/phone to "HomeNetwork"
    - Reconnect IoT devices to "SmartHome"
  - **Verify**: All devices on correct VLANs

- [ ] **Disable Old SSID**
  - **Why**: Force everything onto new VLANs
  - **How**: Settings → WiFi → Old SSID → Disable
  - **Verify**: Old SSID no longer visible

---

## Phase 10: Firewall Rules Implementation

**Status**: 📋 **READY AFTER PHASE 9**

**Goal**: Implement firewall rules to isolate IoT and Guest VLANs.

**Why**: Without firewall rules, VLANs provide no security - devices can still talk across VLANs. Rules enforce "IoT can only access web services, not SSH" and "Guests completely isolated".

**Time Estimate**: 2 hours

**⚠️ CRITICAL**: Rule order matters. Test thoroughly.

See: [docs/network-topology.md#firewall-rules](docs/network-topology.md#firewall-rules)

### Tasks

#### LAN VLAN Firewall Rules

- [ ] **Create LAN → IoT Allow Rule**
  - **Why**: Admins on LAN can manage IoT devices
  - **How**: Firewall → Rules → LAN → Add
    - Action: Pass
    - Protocol: Any
    - Source: LAN net
    - Destination: IoT net (192.168.0.0/24)
    - Description: "Allow LAN to manage IoT"
  - **Priority**: Top of list

- [ ] **Create LAN → Guest Allow Rule**
  - **Why**: Admins on LAN can manage Guest network
  - **How**: Similar to above, destination: Guest net (192.168.10.0/24)

- [ ] **Create LAN → Internet Allow Rule**
  - **Why**: LAN has full internet access
  - **How**:
    - Action: Pass
    - Source: LAN net
    - Destination: Any
    - Description: "Allow LAN to internet"

#### IoT VLAN Firewall Rules

- [ ] **Create IoT → K3s Web Services Allow Rule (Priority 1)**
  - **Why**: IoT devices can watch Jellyfin, use web apps
  - **How**: Firewall → Rules → IoT → Add
    - Action: Pass
    - Protocol: TCP
    - Source: IoT net
    - Destination: Single host or alias
      - Create alias "K3s_Nodes": 192.168.92.11-14
    - Destination Port: 443, 11443
    - Description: "Allow IoT to K3s web services"
  - **Priority**: MUST be FIRST (before block rules)

- [ ] **Create IoT → LAN Block Rule (Priority 2)**
  - **Why**: Block all other LAN access (SSH, etc.)
  - **How**: Firewall → Rules → IoT → Add
    - Action: Block
    - Protocol: Any
    - Source: IoT net
    - Destination: LAN net (192.168.92.0/24)
    - Log: ✅ Yes
    - Description: "Block IoT to LAN (except web services)"
  - **Priority**: After allow rule

- [ ] **Create IoT → Guest Block Rule**
  - **Why**: IoT cannot access Guest network
  - **How**:
    - Action: Block
    - Source: IoT net
    - Destination: Guest net (192.168.10.0/24)
    - Log: ✅ Yes

- [ ] **Create IoT → pfSense Management Block Rule**
  - **Why**: IoT cannot access pfSense UI
  - **How**:
    - Action: Block
    - Source: IoT net
    - Destination: This firewall
    - Destination Port: 443, 80, 22
    - Log: ✅ Yes

- [ ] **Create IoT → DNS Allow Rule**
  - **Why**: IoT devices need DNS resolution
  - **How**:
    - Action: Pass
    - Protocol: UDP
    - Source: IoT net
    - Destination: Any
    - Destination Port: 53

- [ ] **Create IoT → Internet Allow Rule**
  - **Why**: IoT devices need internet (HTTP/S)
  - **How**:
    - Action: Pass
    - Protocol: TCP
    - Source: IoT net
    - Destination: Any
    - Destination Port: 80, 443

- [ ] **Create IoT → Deny All (Implicit)**
  - **Note**: pfSense has implicit deny at end of list
  - **Verify**: No other rules after internet allow

#### Guest VLAN Firewall Rules

- [ ] **Create Guest → LAN Block Rule**
  - **Why**: Guests cannot access internal network
  - **How**:
    - Action: Block
    - Source: Guest net
    - Destination: LAN net
    - Log: ✅ Yes

- [ ] **Create Guest → IoT Block Rule**
  - **Why**: Guests cannot access IoT network
  - **How**:
    - Action: Block
    - Source: Guest net
    - Destination: IoT net
    - Log: ✅ Yes

- [ ] **Create Guest → pfSense Block Rule**
  - **Why**: Guests cannot access pfSense management
  - **How**:
    - Action: Block
    - Source: Guest net
    - Destination: This firewall
    - Destination Port: 443, 80, 22
    - Log: ✅ Yes

- [ ] **Create Guest → DNS Allow Rule**
  - **How**: Same as IoT DNS rule, source: Guest net

- [ ] **Create Guest → Internet Allow Rule**
  - **How**: Same as IoT internet rule, source: Guest net

#### Testing Firewall Rules

- [ ] **Test IoT CAN Access K3s Web Services**
  - **From**: IoT device (192.168.0.x)
  - **Test**: Open https://jellyfin.jardoole.xyz in browser
  - **Expected**: ✅ Works

- [ ] **Test IoT CANNOT SSH to K3s**
  - **From**: IoT device
  - **Test**: `ssh pi@192.168.92.11`
  - **Expected**: ❌ Connection refused or timeout
  - **Verify**: pfSense logs show block

- [ ] **Test IoT CANNOT Access pfSense UI**
  - **From**: IoT device
  - **Test**: Open https://192.168.92.1 in browser
  - **Expected**: ❌ Timeout
  - **Verify**: pfSense logs show block

- [ ] **Test Guest CANNOT Access Jellyfin**
  - **From**: Guest device (192.168.10.x)
  - **Test**: Open https://jellyfin.jardoole.xyz
  - **Expected**: ❌ Cannot connect (no route to LAN)
  - **Verify**: pfSense logs show block

- [ ] **Test Guest CAN Access Internet**
  - **From**: Guest device
  - **Test**: Open https://google.com
  - **Expected**: ✅ Works

- [ ] **Monitor Firewall Logs for 24 Hours**
  - **Why**: Ensure no legitimate traffic blocked
  - **How**: Firewall → Logs → Firewall → Filter by block rules
  - **Action**: Adjust rules if needed

---

## Phase 11: Tailscale Deployment

**Status**: 📋 **READY AFTER PHASE 10**

**Goal**: Deploy Tailscale subnet router on pfSense and direct node on MinIO.

**Why**: Enables secure remote access to all VLANs from laptop/mobile. MinIO can be moved offsite while remaining accessible for backups.

**Time Estimate**: 2 hours

See: [docs/tailscale-setup.md](docs/tailscale-setup.md)

### Tasks - pfSense Tailscale Subnet Router

- [ ] **Install Tailscale Package on pfSense**
  - **How**: System → Package Manager → Available Packages → Search "tailscale" → Install
  - **Wait**: 2 minutes for installation
  - **Verify**: Package appears in installed packages list
  - **Reference**: [docs/tailscale-setup.md#21-install-tailscale-package](docs/tailscale-setup.md#21-install-tailscale-package)

- [ ] **Configure Tailscale on pfSense**
  - **How**: VPN → Tailscale → Settings
    - Enable: ✅ Yes
    - Auth Key: Paste from `vault_passwords/tailscale-subnet-key.txt`
    - Advertise Routes: `192.168.92.0/24,192.168.0.0/24,192.168.10.0/24`
    - Accept Routes: ❌ No
    - Exit Node: ❌ No
    - Accept DNS: ✅ Yes
  - **Save**: Apply configuration
  - **Reference**: [docs/tailscale-setup.md#22-initial-tailscale-configuration](docs/tailscale-setup.md#22-initial-tailscale-configuration)

- [ ] **Start Tailscale Service on pfSense**
  - **How**: Status → Services → Find "tailscale" → Start
  - **Verify**: Status shows "Running" with green checkmark

- [ ] **Verify pfSense Tailscale IP**
  - **How**: SSH to pfSense → `tailscale status`
  - **Expected**: Shows pfSense node with 100.x.x.x IP and advertised routes
  - **Record**: Note pfSense Tailscale IP (e.g., 100.64.0.1)

- [ ] **Approve Subnet Routes in Tailscale Console**
  - **How**: https://login.tailscale.com/admin/machines → Find pfSense
  - **Action**: Click ⋮ → Edit route settings → Approve all three subnets
  - **Verify**: Routes show ✅ status
  - **Reference**: [docs/tailscale-setup.md#25-approve-subnet-routes](docs/tailscale-setup.md#25-approve-subnet-routes)

- [ ] **Configure pfSense Firewall for Tailscale**
  - **Why**: Allow Tailscale clients to access VLANs
  - **Rules**:
    1. Tailscale → LAN net: Pass
    2. Tailscale → IoT net: Pass
    3. Tailscale → Guest net: Pass
  - **Reference**: [docs/tailscale-setup.md#26-configure-pfsense-firewall-for-tailscale](docs/tailscale-setup.md#26-configure-pfsense-firewall-for-tailscale)

### Tasks - MinIO Tailscale Direct Node

- [ ] **Install Tailscale on MinIO**
  - **How**:
    ```bash
    ssh pi@pi-cm5-4.local
    curl -fsSL https://tailscale.com/install.sh | sh
    ```
  - **Verify**: `tailscale version` shows installed version
  - **Reference**: [docs/tailscale-setup.md#31-install-tailscale-debianubuntu](docs/tailscale-setup.md#31-install-tailscale-debianubuntu)

- [ ] **Authenticate MinIO Node**
  - **How**:
    ```bash
    sudo tailscale up --auth-key=<key> --advertise-tags=tag:offsite-nas
    # Paste key from vault_passwords/tailscale-minio-key.txt
    ```
  - **Verify**: `tailscale status` shows "Success"
  - **Reference**: [docs/tailscale-setup.md#32-authenticate-minio-node](docs/tailscale-setup.md#32-authenticate-minio-node)

- [ ] **Record MinIO Tailscale IP**
  - **How**: `tailscale ip -4`
  - **Expected**: Shows 100.x.x.x IP
  - **Save**: Document this IP (needed for Longhorn backup update)

- [ ] **Test MinIO Connectivity**
  - **From MinIO**: `ping 100.64.0.1` (pfSense Tailscale IP)
  - **Expected**: ✅ Works
  - **From MinIO**: `ping 192.168.92.11` (K3s node)
  - **Expected**: ❌ Fails (ACLs will block this)

### Tasks - Tailscale ACLs

- [ ] **Apply ACL Policy to Tailscale**
  - **How**: https://login.tailscale.com/admin/acls → Edit ACL
  - **Paste**: Policy from `tailscale-acl-draft.json` (created in Phase 2)
  - **Verify**: ACL syntax valid, no errors
  - **Save**: Apply policy
  - **Reference**: [docs/tailscale-setup.md#41-edit-acl-policy](docs/tailscale-setup.md#41-edit-acl-policy)

- [ ] **Test ACLs from Laptop**
  - **Prerequisite**: Install Tailscale on laptop (next section)
  - **Tests**:
    - ✅ `ssh pi@100.64.0.10` (MinIO) → Works
    - ✅ `curl http://100.64.0.10:9000` → Works (MinIO S3 API)
    - ✅ `ping 192.168.92.11` → Works (K3s via subnet router)
    - ✅ `ssh pi@192.168.92.11` → Works
  - **Reference**: [docs/tailscale-setup.md#43-test-acls](docs/tailscale-setup.md#43-test-acls)

- [ ] **Test ACLs from MinIO (Verify Blocks)**
  - **From MinIO SSH**:
    - ❌ `ping 192.168.92.11` → Fails (MinIO cannot access LAN)
    - ❌ `ssh pi@192.168.92.11` → Fails
  - **Expected**: All blocked (deny-by-default ACLs working)

### Tasks - Client Devices

- [ ] **Install Tailscale on Laptop**
  - **How**:
    ```bash
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up
    # Follow browser login prompt
    ```
  - **Verify**: `tailscale status` shows connected
  - **Reference**: [docs/tailscale-setup.md#51-install-on-laptop-linux](docs/tailscale-setup.md#51-install-on-laptop-linux)

- [ ] **Install Tailscale on Mobile**
  - **How**: Install app from Play Store / App Store → Sign in
  - **Verify**: App shows "Connected" status
  - **Reference**: [docs/tailscale-setup.md#52-install-on-mobile-androidios](docs/tailscale-setup.md#52-install-on-mobile-androidios)

- [ ] **Test Remote Access from Laptop**
  - **Disconnect from home WiFi** (use mobile hotspot or coffee shop)
  - **Test**:
    - ✅ `ping 192.168.92.11` → Works (subnet router)
    - ✅ `ssh pi@192.168.92.11` → Works
    - ✅ Open https://longhorn.jardoole.xyz → Accessible
  - **Why This Matters**: Proves you can manage cluster remotely

- [ ] **Test Remote Access from Mobile**
  - **Disconnect from home WiFi**
  - **Test**: Open Tailscale app → Browse to `http://192.168.92.11`
  - **Expected**: Can reach services via subnet router

---

## Phase 12: MinIO Migration (Offsite)

**Status**: 📋 **READY AFTER PHASE 11**

**Goal**: Move MinIO server offsite and update Longhorn backup target.

**Why**: Physical separation protects against local disasters (fire, theft). Tailscale maintains secure connectivity without exposing MinIO publicly.

**Time Estimate**: 3 hours (includes physical transport)

**⚠️ RISK**: Backups will fail during migration. Schedule during low-activity period.

See: [docs/network-topology.md#phase-6-minio-migration](docs/network-topology.md#phase-6-minio-migration)

### Tasks

- [ ] **Update Longhorn Backup Target to Tailscale IP**
  - **Why**: Update BEFORE moving MinIO so backups work immediately when powered on offsite
  - **How**: Longhorn UI → Settings → Backup Target
    - Before: `s3://longhorn-backups@us-east-1/` with `http://pi-cm5-4.local:9000`
    - After: `s3://longhorn-backups@us-east-1/` with `http://100.x.x.x:9000` (use MinIO Tailscale IP)
  - **Save**: Apply setting
  - **Reference**: [docs/tailscale-setup.md#62-update-longhorn-settings](docs/tailscale-setup.md#62-update-longhorn-settings)

- [ ] **Test Longhorn Backup with Tailscale IP (While Local)**
  - **Why**: Verify backup works via Tailscale BEFORE moving offsite
  - **How**: Longhorn UI → Volumes → Select volume → Create Backup
  - **Wait**: 5-10 minutes for backup
  - **Verify**: Backup appears in MinIO: `mc ls minio/longhorn-backups/`
  - **Success**: Backup succeeded via Tailscale IP

- [ ] **Document MinIO Tailscale Connection Info**
  - **Save to vault_passwords/**:
    - MinIO Tailscale IP: 100.x.x.x
    - MinIO root user: (from vault)
    - MinIO root password: (from vault)
    - S3 endpoint: `http://100.x.x.x:9000`
    - Web console: `http://100.x.x.x:9001`
  - **Why**: You'll need this info for disaster recovery

- [ ] **Physically Transport MinIO Offsite**
  - **Shutdown**: `ssh pi@pi-cm5-4.local` → `sudo shutdown -h now`
  - **Wait**: 30 seconds for clean shutdown
  - **Disconnect**: Unplug power and ethernet
  - **Transport**: Move to offsite location (friend's house, office, etc.)
  - **Connect**: Power + ethernet at offsite location

- [ ] **Verify MinIO Tailscale Connection from Offsite**
  - **Wait**: 5 minutes for MinIO to boot and connect to Tailscale
  - **Check**: Tailscale admin console → Machines → MinIO shows online
  - **Test**: From laptop: `ping 100.x.x.x` (MinIO Tailscale IP)
  - **Expected**: ✅ Responds

- [ ] **Test MinIO S3 Access from Offsite**
  - **From laptop**: `curl http://100.x.x.x:9000`
  - **Expected**: XML response (S3 API endpoint)
  - **Test**: Open `http://100.x.x.x:9001` in browser
  - **Expected**: MinIO web console loads, can login

- [ ] **Trigger Full Longhorn Backup Suite**
  - **Why**: Ensure all volumes can backup to offsite MinIO
  - **How**: Longhorn UI → Volumes → For each volume → Create Backup
  - **Monitor**: Watch backup progress (should take 10-30 min per volume depending on size)
  - **Verify**: All backups succeed

- [ ] **Verify Backup Data Integrity**
  - **How**: SSH to MinIO → `mc ls minio/longhorn-backups/` → Check file sizes
  - **Expected**: Backup files present with reasonable sizes
  - **Optional**: Test restore one small PVC (prowlarr-config)

- [ ] **Test Port Scan from Internet (Security Check)**
  - **Why**: Ensure MinIO not publicly exposed
  - **How**: From external network (mobile data): `nmap -p 9000,9001 <offsite-public-ip>`
  - **Expected**: Ports closed (MinIO only accessible via Tailscale)

- [ ] **Document Offsite Location**
  - **Save to vault_passwords/**:
    - Physical address
    - Contact person (if applicable)
    - Network details (if accessible locally for troubleshooting)
  - **Why**: Disaster recovery may require physical access

---

## Phase 13: Validation & Documentation

**Status**: 📋 **READY AFTER PHASE 12**

**Goal**: Comprehensive testing and documentation updates.

**Why**: Validate entire migration succeeded. Update docs with final configuration. Create runbooks for common operations.

**Time Estimate**: 4 hours

See: [docs/network-topology.md#phase-7-validation--documentation](docs/network-topology.md#phase-7-validation--documentation)

### Tasks - Disaster Recovery Testing

- [ ] **Perform Test PVC Restore from Offsite MinIO**
  - **Why**: Final proof that backup/restore works end-to-end
  - **How**:
    1. Select test volume (prowlarr-config)
    2. Delete PVC: `kubectl delete pvc prowlarr-config -n media`
    3. Longhorn UI → Backup → Select latest prowlarr-config backup → Restore
    4. Redeploy: `make app-deploy APP=prowlarr`
    5. Verify: Settings intact at https://prowlarr.jardoole.xyz
  - **Expected**: Full restore in < 10 minutes, zero data loss
  - **Document**: Success in disaster recovery doc

### Tasks - Security Audit

- [ ] **Verify IoT Cannot Reach LAN (Except Web Services)**
  - **From IoT device**:
    - ❌ `ssh pi@192.168.92.11` → Blocked
    - ✅ Open https://jellyfin.jardoole.xyz → Works
  - **Check**: pfSense logs show SSH blocks

- [ ] **Verify Guest Completely Isolated**
  - **From Guest device**:
    - ❌ `ping 192.168.92.11` → Blocked
    - ❌ Open https://jellyfin.jardoole.xyz → Blocked
    - ✅ Open https://google.com → Works

- [ ] **Verify MinIO Cannot Access Cluster**
  - **From MinIO**: `ping 192.168.92.11` → Blocked
  - **Check**: Tailscale ACLs enforcing deny-by-default

- [ ] **Port Scan pfSense from Internet**
  - **Why**: Ensure no new public exposures from migration
  - **How**: From external network: `nmap -p 1-10000 <your-wan-ip>`
  - **Expected**: Only port 443 open (existing port forward), Tailscale not exposed

### Tasks - Performance Testing

- [ ] **Measure Tailscale Throughput for Backups**
  - **Why**: Baseline performance for monitoring
  - **How**: From K3s node: `iperf3 -c 100.x.x.x` (MinIO Tailscale IP)
  - **Record**: Throughput (Mbps) in documentation
  - **Expected**: 10-50 Mbps (depends on internet speeds, DERP relay)

- [ ] **Baseline Service Response Times**
  - **Why**: Ensure migration didn't degrade performance
  - **How**: `curl -w "@curl-format.txt" -o /dev/null -s https://jellyfin.jardoole.xyz`
  - **Record**: Response time in documentation
  - **Expected**: < 500ms (unchanged from before migration)

### Tasks - Documentation Updates

- [ ] **Update docs/disaster-recovery.md**
  - **Content**:
    - Tested PVC restore procedure
    - MinIO offsite restore procedure
    - Full cluster rebuild steps
    - Tailscale recovery (if cluster down)
  - **Include**: Screenshots from actual testing

- [ ] **Update docs/pfsense-integration-architecture.md**
  - **Add**: Tailscale subnet router section
  - **Update**: Port forwarding configuration (WAN:443 → K3s:11443)
  - **Add**: VLAN configuration overview

- [ ] **Update docs/project-structure.md**
  - **Add**: Network architecture section
    - Three VLANs: LAN, IoT, Guest
    - Tailscale overlay network
    - MinIO offsite backup architecture
  - **Add**: Diagram showing full infrastructure

- [ ] **Create docs/runbooks/add-tailscale-device.md**
  - **Content**: How to add new laptop/mobile to Tailscale
  - **Include**: ACL updates if needed

- [ ] **Create docs/runbooks/onboard-iot-device.md**
  - **Content**: How to connect new IoT device to SmartHome SSID
  - **Include**: Firewall rule verification steps

- [ ] **Create docs/runbooks/troubleshoot-vlan-issues.md**
  - **Content**:
    - Device cannot reach internet
    - Device on wrong VLAN
    - Firewall rule troubleshooting
    - UniFi Controller adoption issues

- [ ] **Update README.md (Project Root)**
  - **Add**: Network architecture summary
  - **Update**: Infrastructure diagram with VLANs
  - **Link**: To new network documentation

### Tasks - Final Verification

- [ ] **Create Network Architecture Diagram**
  - **Tool**: Draw.io or similar
  - **Content**: Full infrastructure showing:
    - pfSense with VLANs
    - Switch with port assignments
    - AP with multi-SSID
    - K3s cluster
    - Tailscale overlay
    - MinIO offsite
  - **Save**: `docs/diagrams/network-architecture-final.png`

- [ ] **Review and Close Migration TODO Items**
  - **Action**: Mark all TODO items as complete
  - **Document**: Lessons learned
  - **Celebrate**: Migration complete! 🎉

---

## Phase 14: Ongoing Monitoring (Post-Migration)

**Status**: 📋 **STARTS AFTER PHASE 13**

**Goal**: Establish monitoring routine for new network infrastructure.

**Why**: Catch issues early (offline Tailscale nodes, failed backups, firewall violations).

### Daily Tasks

- [ ] **Check Longhorn Backup Status**
  - **How**: Longhorn UI → Backup → Review last 24 hours
  - **Expected**: All scheduled backups succeeded
  - **If failed**: Check MinIO Tailscale connectivity

- [ ] **Review pfSense Firewall Logs**
  - **How**: Firewall → Logs → Firewall → Filter by "Block"
  - **Look for**: Unexpected blocks (legitimate traffic blocked)
  - **Action**: Adjust firewall rules if needed

### Weekly Tasks

- [ ] **Verify Tailscale Node Health**
  - **How**: https://login.tailscale.com/admin/machines
  - **Check**: All nodes show green (online)
  - **Expected**: pfSense, MinIO, laptop, mobile all online

- [ ] **Test MinIO Reachability from Offsite**
  - **How**: From laptop via Tailscale: `ping 100.x.x.x`
  - **Expected**: Responds
  - **If failed**: Check Tailscale status on MinIO, contact offsite location

- [ ] **Test Random PVC Restore**
  - **Why**: Continuous backup validation
  - **How**: Pick random small volume → test restore
  - **Frequency**: Weekly or bi-weekly

### Monthly Tasks

- [ ] **Review Tailscale ACLs**
  - **Why**: Ensure ACLs still correct as devices added/removed
  - **How**: Tailscale admin → ACLs → Review policy
  - **Update**: If new devices or access patterns

- [ ] **Audit IoT Device List**
  - **Why**: Remove stale devices
  - **How**: UniFi Controller → Clients → Review SmartHome SSID clients
  - **Action**: Forget devices no longer used

- [ ] **Update Tailscale Clients**
  - **pfSense**: System → Package Manager → Check for updates
  - **MinIO**: `sudo apt update && sudo apt upgrade tailscale`
  - **Laptop**: `sudo apt upgrade tailscale`
  - **Mobile**: Update via app store

### Quarterly Tasks

- [ ] **Full Disaster Recovery Drill**
  - **Scenario**: Cluster completely destroyed
  - **Practice**: Rebuild from scratch using docs/disaster-recovery.md
  - **Time**: Should complete in < 2 hours
  - **Update**: Documentation if process changed

- [ ] **Review Firewall Rules for Optimization**
  - **Check**: Are all rules still needed?
  - **Simplify**: Combine redundant rules if possible
  - **Test**: No regressions after changes

- [ ] **Network Security Review**
  - **Check**: Port scan from internet
  - **Review**: Tailscale audit logs
  - **Verify**: No unexpected access patterns

### Annual Tasks

- [ ] **Audit Entire Network Topology**
  - **Review**: docs/network-topology.md accuracy
  - **Update**: Diagrams if infrastructure changed
  - **Document**: Any deviations from original plan

- [ ] **Rotate Tailscale Auth Keys**
  - **Why**: Security best practice
  - **How**: Generate new keys → update pfSense/MinIO → revoke old keys
  - **Reference**: [docs/tailscale-setup.md#74-rotate-auth-keys](docs/tailscale-setup.md#74-rotate-auth-keys)

---

## Quick Reference

### Critical IPs (Post-Migration)

| Device | Current IP | VLAN | Access |
|--------|-----------|------|--------|
| pfSense LAN | 192.168.92.1 | LAN (1) | https://192.168.92.1 |
| pfSense IoT | 192.168.0.1 | IoT (10) | Gateway |
| pfSense Guest | 192.168.10.1 | Guest (20) | Gateway |
| Ubiquiti Switch | 192.168.92.2 | LAN (1) | Via UniFi Controller |
| Ubiquiti AP | 192.168.92.3 | LAN (1) | Via UniFi Controller |
| pi-cm5-1 | 192.168.92.11 | LAN (1) | ssh pi@192.168.92.11 |
| pi-cm5-2 | 192.168.92.12 | LAN (1) | ssh pi@192.168.92.12 |
| pi-cm5-3 | 192.168.92.13 | LAN (1) | ssh pi@192.168.92.13 |
| beelink | 192.168.92.14 | LAN (1) | ssh user@192.168.92.14 |
| MinIO (offsite) | 100.x.x.x | Tailscale | http://100.x.x.x:9001 |
| UniFi Controller | - | LAN (K3s) | https://unifi.jardoole.xyz |

### WiFi SSIDs (Post-Migration)

| SSID | VLAN | Subnet | Purpose |
|------|------|--------|---------|
| HomeNetwork | LAN (1) | 192.168.92.0/24 | Trusted devices |
| SmartHome | IoT (10) | 192.168.0.0/24 | IoT devices |
| Guest | Guest (20) | 192.168.10.0/24 | Guest devices |

### Useful Commands (Post-Migration)

```bash
# Check Tailscale status
tailscale status

# SSH via Tailscale (from anywhere)
ssh pi@192.168.92.11  # via subnet router

# Test MinIO from K3s node
curl http://100.x.x.x:9000

# Check pfSense firewall logs
# Firewall → Logs → Firewall

# Monitor Longhorn backups
kubectl logs -n longhorn-system -l app=longhorn-backup-controller
```

### Documentation Map

- **Overview**: `docs/network-topology.md` (architecture, phases)
- **Tailscale**: `docs/tailscale-setup.md` (complete setup guide)
- **VLANs**: `docs/vlan-configuration.md` (pfSense + Ubiquiti)
- **UniFi**: `docs/unifi-controller-deployment.md` (K3s deployment)
- **Disaster Recovery**: `docs/disaster-recovery.md` (restore procedures)
- **Runbooks**: `docs/runbooks/` (common operations)

---

## Success Criteria (Migration Complete When...)

✅ All VLANs configured and operational
✅ Three WiFi SSIDs working (HomeNetwork, SmartHome, Guest)
✅ Firewall rules enforced (IoT limited, Guest isolated)
✅ Tailscale subnet router advertising all VLANs
✅ MinIO offsite and connected via Tailscale
✅ Longhorn backups succeeding to offsite MinIO
✅ Tested PVC restore from offsite backup
✅ Remote access working (laptop/mobile via Tailscale)
✅ Documentation complete and accurate
✅ No services degraded or broken

**When all ✅ complete**: Network migration successful! 🎉

---

**Last Updated**: 2025-11-18
**Next Review**: After Phase 0 completion
