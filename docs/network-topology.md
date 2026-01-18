# Network Topology Documentation

**Last Updated**: 2025-11-21
**Status**: Migration Planning
**Target Completion**: Q1 2026

## Overview

This document describes the current network topology and the planned migration to a segmented network with WireGuard VPN remote access, IoT isolation, and offsite backup capabilities.

**Migration Goal**: Transform from single-VLAN architecture to multi-VLAN segmented network with secure remote access via WireGuard VPN while maintaining public service exposure through pfSense port forwarding.

---

## Current Network Topology

### Architecture Diagram

```mermaid
graph TB
    Internet[Internet]
    WAN[pfSense WAN]
    PF[pfSense Router<br/>NAT + Firewall]
    Switch[Ubiquiti Switch 8<br/>4x PoE]
    AP[Ubiquiti AP Pro 6<br/>Single SSID]
    TuringPi[Turing Pi 2<br/>3x Pi CM5]
    Beelink[Beelink<br/>K3s Worker]
    MinIO[MinIO Server<br/>pi-cm5-4]

    Internet --> WAN
    WAN --> PF
    PF -->|"Crap LAN<br/>192.168.0.0/24"| Switch
    Switch -->|PoE Port 1| MinIO
    Switch -->|PoE Port 2| AP
    Switch -->|Port 3| TuringPi
    Switch -->|Port 4| Beelink

    AP -.->|WiFi| Laptop[Laptop/Mobile]
    AP -.->|WiFi| IoT[IoT Devices]

    TuringPi -->|Hosts| CM5-1[pi-cm5-1<br/>Control Plane]
    TuringPi -->|Hosts| CM5-2[pi-cm5-2<br/>Control Plane]
    TuringPi -->|Hosts| CM5-3[pi-cm5-3<br/>Control Plane]

    style PF fill:#f9f,stroke:#333,stroke-width:2px
    style Switch fill:#bbf,stroke:#333,stroke-width:2px
    style MinIO fill:#bfb,stroke:#333,stroke-width:2px
    style TuringPi fill:#fbb,stroke:#333,stroke-width:2px
```

### Current Configuration

| Component | VLAN | IP Range | Notes |
|-----------|------|----------|-------|
| pfSense "Crap LAN" | N/A | 192.168.0.1 | Gateway (current single network) |
| All devices | N/A | 192.168.0.0/24 | Everything on same network currently |
| Ubiquiti Switch | N/A | 192.168.0.2 | Management IP |
| Ubiquiti AP | N/A | 192.168.0.3 | Management IP |
| K3s Nodes | N/A | 192.168.0.11-14 | Should move to LAN VLAN |
| MinIO (pi-cm5-4) | N/A | 192.168.0.15 | Moving offsite |
| Laptop/Mobile | N/A | DHCP (192.168.0.x) | Via WiFi |
| IoT Devices | N/A | DHCP (192.168.0.x) | Via WiFi, no isolation |

**K3s Cluster Network**:
- Pod CIDR: `10.42.0.0/16`
- Service CIDR: `10.43.0.0/16`
- Flannel backend: VXLAN (port 8472/udp)
- Cluster domain: `jardoole.xyz`

**Public Services** (planned):
- Services will be exposed via pfSense port forwarding: WAN:443 → K3s:11443
- Traefik ingress controller on K3s will handle routing to services
- Example: `https://jellyfin.jardoole.xyz`, `https://radarr.jardoole.xyz`

### Current Issues

1. ❌ **No network segmentation** - All devices (servers + IoT) on same VLAN
2. ❌ **IoT devices can access servers** - No firewall isolation
3. ❌ **No remote access** - Cannot access cluster from mobile/laptop securely
4. ❌ **MinIO on local network** - Vulnerable to physical theft
5. ❌ **Single WiFi SSID** - Cannot separate trusted vs untrusted devices

---

## Target Network Topology

### Architecture Diagram

```mermaid
graph TB
    Internet[Internet]
    WAN[pfSense WAN]
    PF[pfSense Router<br/>WireGuard VPN Server<br/>NAT + Firewall]
    Switch[Ubiquiti Switch 8<br/>Port-based VLANs]
    AP[Ubiquiti AP Pro 6<br/>Multi-SSID:<br/>Home + IoT + Guest]
    TuringPi[Turing Pi 2<br/>3x Pi CM5]
    Beelink[Beelink<br/>K3s Worker]
    MinIO[MinIO Server Offsite<br/>WireGuard Peer]

    WG[WireGuard VPN<br/>10.99.0.0/24]
    Laptop[Laptop<br/>WireGuard Client]
    Mobile[Mobile<br/>WireGuard Client]
    Guest[Guest Devices]

    Internet --> WAN
    WAN --> PF
    PF -->|"LAN VLAN 1<br/>192.168.92.0/24"| Switch

    Switch -->|Ports 2-4: LAN VLAN| TuringPi
    Switch -->|Port 5: LAN VLAN| Beelink
    Switch -->|Port 6: Trunk<br/>LAN+IoT+Guest VLANs| AP

    AP -.->|"WiFi: HomeNetwork<br/>LAN VLAN 1"| Laptop
    AP -.->|"WiFi: SmartHome<br/>IoT VLAN 10"| IoT[IoT Devices<br/>192.168.0.0/24]
    AP -.->|"WiFi: Guest<br/>Guest VLAN 20"| Guest

    TuringPi -->|Hosts| CM5-1[pi-cm5-1<br/>Control Plane]
    TuringPi -->|Hosts| CM5-2[pi-cm5-2<br/>Control Plane]
    TuringPi -->|Hosts| CM5-3[pi-cm5-3<br/>Control Plane]

    PF -.->|WireGuard Server<br/>10.99.0.1| WG
    MinIO -.->|WireGuard Peer<br/>10.99.0.10| WG
    Laptop -.->|WireGuard Client<br/>10.99.0.20| WG
    Mobile -.->|WireGuard Client<br/>10.99.0.30| WG

    WG -.->|VPN Access| CM5-1
    WG -.->|VPN Access| CM5-2
    WG -.->|VPN Access| CM5-3
    WG -.->|VPN Access| Beelink
    WG -.->|Restic Backups<br/>S3 API| MinIO

    style PF fill:#f9f,stroke:#333,stroke-width:4px
    style Switch fill:#bbf,stroke:#333,stroke-width:2px
    style MinIO fill:#bfb,stroke:#333,stroke-width:4px
    style WG fill:#ffd,stroke:#333,stroke-width:2px,stroke-dasharray: 5 5
    style TuringPi fill:#fbb,stroke:#333,stroke-width:2px
```

### Target Configuration

#### Network Segmentation

| Network | VLAN ID | Subnet | Gateway | Purpose |
|---------|---------|--------|---------|---------|
| LAN | 1 (native) | 192.168.92.0/24 | 192.168.92.1 | Servers, admin devices |
| IoT | 10 | 192.168.0.0/24 | 192.168.0.1 | Smart home, cameras (keeps current subnet) |
| Guest | 20 | 192.168.10.0/24 | 192.168.10.1 | Guest WiFi (isolated) |

#### Device Assignments

| Device | VLAN | IP Address | Access Method |
|--------|------|------------|---------------|
| pfSense LAN | 1 | 192.168.92.1 | Direct |
| pfSense IoT | 10 | 192.168.0.1 | Direct |
| pfSense Guest | 20 | 192.168.10.1 | Direct |
| Ubiquiti Switch | 1 | 192.168.92.2 | LAN + WireGuard VPN |
| Ubiquiti AP | 1 | 192.168.92.3 | LAN + WireGuard VPN |
| pi-cm5-1 | 1 | 192.168.92.11 | LAN + WireGuard VPN |
| pi-cm5-2 | 1 | 192.168.92.12 | LAN + WireGuard VPN |
| pi-cm5-3 | 1 | 192.168.92.13 | LAN + WireGuard VPN |
| beelink | 1 | 192.168.92.14 | LAN + WireGuard VPN |
| MinIO (offsite) | N/A | 10.99.0.10 (WireGuard) | WireGuard VPN only |
| IoT devices | 10 | 192.168.0.100+ | IoT VLAN via AP |
| Guest devices | 20 | 192.168.10.100+ | Guest VLAN via AP |

#### WiFi SSIDs

| SSID | VLAN | Security | Purpose |
|------|------|----------|---------|
| HomeNetwork | 1 (LAN) | WPA3 | Trusted devices (laptops, phones) |
| SmartHome | 10 (IoT) | WPA2 | IoT devices (cameras, sensors) |
| Guest | 20 (Guest) | WPA2 | Guest/visitor devices (isolated) |

#### Switch Port Configuration

| Port | Mode | VLANs | Connected Device |
|------|------|-------|------------------|
| Port 1 (Uplink) | Trunk | 1, 10, 20 | pfSense LAN interface |
| Port 2 | Access | 1 | pi-cm5-1 (via Turing Pi) |
| Port 3 | Access | 1 | pi-cm5-2 (via Turing Pi) |
| Port 4 | Access | 1 | pi-cm5-3 (via Turing Pi) |
| Port 5 (PoE) | Access | 1 | beelink |
| Port 6 (PoE) | Trunk | 1, 10, 20 | Ubiquiti AP Pro 6 |
| Port 7 | Available | - | Expansion |
| Port 8 | Available | - | Expansion |

**Note**: Port 6 must be trunk to carry LAN (management), IoT (SmartHome SSID), and Guest (Guest SSID) traffic.

---

## WireGuard VPN Configuration

### WireGuard Peers

| Peer | WireGuard IP | Allowed IPs | Persistent Keepalive | Purpose |
|------|--------------|-------------|---------------------|---------|
| pfSense (Server) | 10.99.0.1/24 | N/A | N/A | VPN hub, routes to all VLANs |
| MinIO (offsite) | 10.99.0.10/32 | 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24, 10.99.0.0/24 | 25s | S3 backup target, full network access |
| Laptop | 10.99.0.20/32 | 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24, 10.99.0.0/24 | None | Admin access, split tunnel |
| Mobile | 10.99.0.30/32 | 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24, 10.99.0.0/24 | None | Admin access, split tunnel |

**Key Configuration Details**:
- **VPN Subnet**: 10.99.0.0/24
- **pfSense Port**: 51820/UDP (WAN interface)
- **Hub-and-Spoke Topology**: All peers connect to pfSense, no peer-to-peer
- **Persistent Keepalive**: Only MinIO (behind NAT) uses 25s keepalive
- **Split Tunnel**: Laptop and phone only route home subnets through VPN

### WireGuard Interface Firewall Rules (pfSense)

Access control is enforced via pfSense firewall rules on the WireGuard interface:

| Priority | Action | Source | Destination | Ports | Description |
|----------|--------|--------|-------------|-------|-------------|
| 1 | Allow | 10.99.0.20/32, 10.99.0.30/32 | Any | Any | Laptop and phone have full access |
| 2 | Allow | 10.99.0.10/32 | 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24 | Any | MinIO can reach all VLANs (backup traffic) |
| 3 | Block | 10.99.0.10/32 | Any | Any | MinIO cannot reach other destinations |
| 4 | Block | Any | Any | Any | Deny all other VPN traffic |

**Security Model**:
- **One-way access**: MinIO can receive connections but cannot initiate outbound (rule 2 allows inbound, rule 3 blocks rest)
- **Admin full access**: Laptop and phone have unrestricted access to all networks
- **No peer-to-peer**: WireGuard peers cannot directly communicate with each other
- **Explicit allow**: All rules are explicitly defined (no implicit allows)

---

## Firewall Rules

### pfSense Firewall Rules

#### LAN VLAN (192.168.92.0/24) Rules

| Priority | Action | Source | Destination | Ports | Description |
|----------|--------|--------|-------------|-------|-------------|
| 1 | Allow | LAN net | IoT net | Any | Admin can manage IoT devices |
| 2 | Allow | LAN net | Guest net | Any | Admin can manage guest network |
| 3 | Allow | LAN net | Any | Any | LAN has full internet access |
| 4 | Allow | LAN net | pfSense | 443,80 | Web UI access |

#### IoT VLAN (192.168.0.0/24) Rules

| Priority | Action | Source | Destination | Ports | Description |
|----------|--------|--------|-------------|-------|-------------|
| 1 | Allow | IoT net | 192.168.92.11-14 | 443,11443 | **Allow IoT → K3s web services (Jellyfin, etc.)** |
| 2 | Block | IoT net | 192.168.92.0/24 | Any | Block all other LAN access (SSH, etc.) |
| 3 | Block | IoT net | 192.168.10.0/24 | Any | Block guest network access |
| 4 | Block | IoT net | pfSense | 443,80,22 | Block management access |
| 5 | Allow | IoT net | Any | 53 | Allow DNS queries |
| 6 | Allow | IoT net | Any | 80,443 | Allow internet (HTTP/S) |
| 7 | Block | IoT net | Any | Any | Deny all other traffic |

**Note**: Rule 1 allows IoT devices to access web services running on K3s (same ports exposed publicly). This enables smart TVs/tablets to watch Jellyfin while maintaining security.

####Guest VLAN (192.168.10.0/24) Rules

| Priority | Action | Source | Destination | Ports | Description |
|----------|--------|--------|-------------|-------|-------------|
| 1 | Block | Guest net | 192.168.92.0/24 | Any | Block all LAN access |
| 2 | Block | Guest net | 192.168.0.0/24 | Any | Block IoT network access |
| 3 | Block | Guest net | pfSense | 443,80,22 | Block management access |
| 4 | Allow | Guest net | Any | 53 | Allow DNS queries |
| 5 | Allow | Guest net | Any | 80,443 | Allow internet (HTTP/S) only |
| 6 | Block | Guest net | Any | Any | Deny all other traffic |

**Logging**: Enable logging on all "Block" rules for security monitoring.

---

## Public Service Exposure

### Port Forwarding Configuration

Public services are exposed via pfSense port forwarding to the K3s cluster:

```
Internet (HTTPS:443)
  → pfSense Port Forward (WAN:443 → K3s:11443)
    → Traefik Ingress (K3s, listening on :443 and :11443)
      → Application Pods
```

**Configuration**:
- Public port: WAN interface port 443
- Forward to: K3s nodes (192.168.92.11-14) port 11443
- Traefik ingress controller handles routing to services based on hostname
- Separate ingress configured for port 11443 (public) and 443 (internal/IoT)

**Examples**:
- `https://jellyfin.jardoole.xyz` → Routes to Jellyfin pod via Traefik
- `https://radarr.jardoole.xyz` → Routes to Radarr pod via Traefik
- IoT devices access same services on ports 443 or 11443 (firewall rules allow)

**SSL Certificates**: Let's Encrypt via cert-manager with Cloudflare DNS-01 challenge (automated renewal)

**Network Isolation**: WireGuard VPN operates on separate tunnel and does not affect public service exposure.

---

## Comparison: Current vs Target

| Feature | Current State | Target State | Benefit |
|---------|---------------|--------------|---------|
| Network Segmentation | ❌ Single VLAN | ✅ Multi-VLAN (LAN + IoT + Guest) | IoT isolation |
| IoT Access to Servers | ⚠️ Unrestricted | ✅ Limited (web only) | Security hardening |
| Remote Access | ❌ None (or VPN?) | ✅ WireGuard VPN | Secure mobile/laptop access |
| MinIO Location | ⚠️ Local (theft risk) | ✅ Offsite (WireGuard VPN) | Physical security |
| WiFi Segmentation | ❌ Single SSID | ✅ Multi-SSID (Home/IoT/Guest) | Easy device separation |
| Backup Security | ⚠️ Local network | ✅ WireGuard firewall rules | One-way access only |
| Public Services | ✅ Port Forward | ✅ Port Forward (unchanged) | No disruption |
| Management Complexity | 🟢 Low | 🟡 Medium | Worth trade-off |

---

## Implementation Phases

### Phase 1: Documentation & Planning (Week 1-2)

**Goal**: Complete WireGuard planning and deploy UniFi Controller

**Tasks**:
1. ✅ Research WireGuard options (completed)
2. ✅ Create WireGuard setup guide (completed)
3. Create VLAN configuration guide
4. Create UniFi Controller deployment guide
5. Deploy UniFi Controller on K3s cluster
6. Adopt Ubiquiti switch and AP

**Success Criteria**:
- UniFi Controller accessible via web UI
- Switch and AP adopted successfully
- All documentation complete
- No disruption to existing services

**Rollback**: Remove UniFi Controller deployment

---

### Phase 2: VLAN Configuration (Week 3-4)

**Goal**: Create LAN, IoT, and Guest VLANs, configure switch port assignments

**Tasks**:
1. Create LAN VLAN (VLAN 1) in pfSense: 192.168.92.0/24
2. Create IoT VLAN (VLAN 10) in pfSense: 192.168.0.0/24
3. Create Guest VLAN (VLAN 20) in pfSense: 192.168.10.0/24
4. Configure DHCP servers for each VLAN
5. Assign static IPs to K3s nodes (192.168.92.11-14)
6. Configure switch ports (access vs trunk)
7. Test connectivity within each VLAN
8. Document VLAN configuration

**Success Criteria**:
- K3s nodes accessible on LAN VLAN (192.168.92.x)
- IoT devices remain on IoT VLAN (192.168.0.x)
- Guest VLAN configured (192.168.10.x)
- AP management accessible from LAN VLAN
- All devices have working internet access

**Rollback**: Revert switch to default VLAN, restore previous IP assignments

---

### Phase 3: Multi-SSID WiFi (Week 5)

**Goal**: Configure AP with multiple SSIDs mapped to VLANs

**Tasks**:
1. Create "HomeNetwork" SSID → LAN VLAN (192.168.92.0/24)
2. Create "SmartHome" SSID → IoT VLAN (192.168.0.0/24)
3. Create "Guest" SSID → Guest VLAN (192.168.10.0/24)
4. Set switch port 6 (AP uplink) to trunk mode (VLANs 1, 10, 20)
5. Test WiFi connectivity on all three SSIDs
6. Verify VLAN tagging (devices on correct VLANs)
7. Migrate IoT devices to "SmartHome" SSID

**Success Criteria**:
- Laptop connects to "HomeNetwork", gets 192.168.92.x IP
- IoT devices connect to "SmartHome", get 192.168.0.x IPs
- Guest devices connect to "Guest", get 192.168.10.x IPs
- All three SSIDs have working internet
- Devices on correct VLANs per `arp -a`

**Rollback**: Disable "SmartHome" and "Guest" SSIDs, revert to single SSID

---

### Phase 4: Firewall Rules (Week 6)

**Goal**: Implement IoT and Guest isolation firewall rules

**Tasks**:
1. Create IoT → K3s web services allow rule (ports 443, 11443)
2. Create IoT → LAN block rule (all other traffic)
3. Create IoT → Guest block rule
4. Create IoT → pfSense management block rule
5. Create IoT → Internet allow rule (DNS, HTTP/S)
6. Create Guest → LAN/IoT block rules
7. Create Guest → Internet allow rule (DNS, HTTP/S only)
8. Enable logging on all block rules
9. Test IoT device CAN reach K3s web services (Jellyfin)
10. Test IoT device CANNOT reach K3s SSH
11. Test Guest device CANNOT reach any internal networks
12. Monitor firewall logs for violations

**Success Criteria**:
- IoT device **can** access https://192.168.92.11 (Jellyfin on K3s)
- IoT device **cannot** SSH to 192.168.92.11 (K3s node)
- IoT device **cannot** access https://192.168.92.1 (pfSense UI)
- Guest device **cannot** ping 192.168.92.11 (K3s node)
- Guest device **cannot** ping 192.168.0.100 (IoT device)
- All devices **can** ping 8.8.8.8 (internet)
- All devices **can** resolve DNS queries
- Firewall logs show blocked attempts

**Rollback**: Disable IoT and Guest firewall rules, restore any-to-any access

---

### Phase 5: WireGuard VPN Deployment (Week 7-8)

**Goal**: Deploy WireGuard VPN on pfSense and configure all peers

**Tasks**:
1. Generate WireGuard keypairs (pfSense, MinIO, laptop, phone)
2. Configure WireGuard tunnel on pfSense (10.99.0.1/24, port 51820)
3. Add MinIO peer (10.99.0.10/32, persistent keepalive 25s)
4. Add laptop peer (10.99.0.20/32, split tunnel)
5. Add phone peer (10.99.0.30/32, split tunnel)
6. Configure WireGuard interface firewall rules (one-way access for MinIO)
7. Configure LAN rules (allow LAN → MinIO:9000-9001)
8. Install WireGuard on MinIO, configure wg0.conf
9. Test connectivity: Laptop → K3s nodes via WireGuard
10. Test connectivity: Laptop → MinIO via WireGuard

**Success Criteria**:
- Laptop (WireGuard) can SSH to pi-cm5-1 via 192.168.92.11
- Laptop (WireGuard) can access MinIO S3 API via `http://10.99.0.10:9000`
- MinIO **cannot** initiate connections to K3s nodes (blocked by firewall)
- WireGuard handshake active for all peers (`wg show`)
- Can access all three VLANs from WireGuard clients
- Split tunnel working (internet traffic direct, not via VPN)

**Rollback**: Disable WireGuard tunnel in pfSense, remove wg0 interface from MinIO

---

### Phase 6: MinIO Migration (Week 9-10)

**Goal**: Move MinIO offsite, update restic backup target

**Tasks**:
1. Update restic backup target to MinIO WireGuard IP:
   ```yaml
   # Before: http://pi-cm5-4.local:9000
   # After: http://10.99.0.10:9000
   ```
2. Test restic backup job (manual trigger)
3. Verify backup appears in MinIO bucket
4. Document MinIO WireGuard connection info for disaster recovery
5. Physically move MinIO to offsite location
6. Power on MinIO, verify WireGuard connection (`wg show`)
7. Trigger full restic backup suite
8. Monitor backup success

**Success Criteria**:
- restic backups succeed via WireGuard VPN
- MinIO reachable from offsite location (WireGuard handshake active)
- Backup data integrity verified (random restore test)
- No public exposure of MinIO (port scan shows closed)

**Rollback**:
- Restore MinIO to local network
- Revert restic backup target to local IP
- Keep WireGuard configured for future retry

---

### Phase 7: Validation & Documentation (Week 11-12)

**Goal**: Comprehensive testing and documentation updates

**Tasks**:
1. Perform disaster recovery test:
   - Restore one PVC from MinIO backup
   - Verify data integrity
2. Security audit:
   - Verify IoT devices cannot reach LAN
   - Verify MinIO cannot initiate connections to cluster
   - Port scan pfSense from internet (verify no new exposures)
3. Performance test:
   - Measure WireGuard throughput for backups (`iperf3`)
   - Baseline Traefik response times (ensure unchanged)
4. Update documentation:
   - `docs/network-topology.md` (this document)
   - `docs/disaster-recovery.md` (new, MinIO restore procedures)
   - `docs/pfsense-integration-architecture.md` (add WireGuard section)
5. Create runbook for common operations:
   - Adding new WireGuard peer
   - Onboarding new IoT device
   - Troubleshooting VLAN issues

**Success Criteria**:
- PVC restore succeeds from offsite MinIO
- IoT isolation confirmed (cannot access LAN except web services on 192.168.92.11-14:443,11443)
- Guest isolation confirmed (cannot access any internal networks)
- MinIO isolation confirmed (firewall rules enforced)
- Public services unchanged (Jellyfin, Radarr, etc. still accessible)
- Documentation complete and reviewed

**No rollback** - migration complete!

---

## Risk Assessment & Mitigation

### High-Risk Items

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Misconfigured firewall rules break K3s cluster | 🔴 Critical | 🟡 Medium | Test rules in lab first, have console access to pfSense |
| WireGuard tunnel failure breaks remote access | 🟡 Medium | 🟢 Low | Keep MinIO as independent peer, monitor handshakes |
| VLAN misconfiguration causes network outage | 🔴 Critical | 🟡 Medium | Document rollback steps, test during low-usage window |
| MinIO offsite loses WireGuard connectivity | 🟡 Medium | 🟡 Medium | Monitor WireGuard handshakes, persistent keepalive 25s |
| UniFi Controller failure prevents switch management | 🟢 Low | 🟢 Low | Can factory reset switch and reconfigure manually |

### Rollback Strategy

Each phase includes specific rollback procedures. General rollback principles:

1. **Network changes**: Keep pfSense console access (physical keyboard/monitor)
2. **Service changes**: Test restic backups before AND after each phase
3. **Configuration backup**: Export pfSense config before changes
4. **Documentation**: Maintain "before" and "after" network diagrams

---

## Monitoring & Maintenance

### Ongoing Monitoring

1. **Firewall Logs** (pfSense):
   - Monitor IoT → LAN block attempts
   - Alert on unexpected traffic patterns

2. **WireGuard Status**:
   - Check WireGuard peer handshakes: `wg show` on pfSense
   - Monitor MinIO keepalive (should be < 1 min ago)
   - Verify all peers show "latest handshake"

3. **Backup Jobs** (restic):
   - Daily: Verify backup success (`ssh beelink "restic snapshots"`)
   - Weekly: Test restore of one directory
   - Monthly: Full disaster recovery drill

4. **Network Performance**:
   - Baseline WireGuard throughput: `iperf3` between laptop and K3s node
   - Monitor Traefik response times (Grafana dashboard)

### Maintenance Tasks

**Monthly**:
- Review WireGuard firewall rules for accuracy
- Audit IoT device list (remove stale devices)
- Verify MinIO reachable from offsite

**Quarterly**:
- Update WireGuard on all devices (pfSense, MinIO, clients)
- Review firewall rules for optimization
- Test disaster recovery procedures

**Annually**:
- Audit entire network topology
- Review security posture
- Rotate WireGuard keys
- Plan future enhancements

---

## Future Enhancements

### Potential Additions

1. **Guest WiFi VLAN** (VLAN 20):
   - Isolated network for visitors
   - Portal-based authentication
   - Time-limited access

2. **WireGuard on Individual K3s Nodes**:
   - Optional: Install WireGuard on each K3s node for direct peer connections
   - Better performance than routing through pfSense for some use cases

3. **Network Monitoring Stack**:
   - Deploy Prometheus + Grafana for network metrics
   - Monitor VLAN traffic, firewall rule hits
   - Alert on anomalies

4. **Automated Failover**:
   - Secondary MinIO location (geographic redundancy)
   - Automated WireGuard route failover

5. **IPv6 Support**:
   - Enable IPv6 on all VLANs
   - Configure WireGuard IPv6

---

## Troubleshooting

### Common Issues

#### 1. Device Cannot Reach Internet After VLAN Migration

**Symptoms**: Device gets IP but no internet connectivity

**Diagnosis**:
```bash
# Check DHCP assignment
ip addr show

# Check gateway
ip route show

# Test DNS
nslookup google.com

# Test gateway ping
ping 192.168.92.1
```

**Solutions**:
- Verify DHCP server configured on VLAN
- Check firewall rules (allow VLAN → Internet)
- Verify NAT rules in pfSense

#### 2. IoT Device Can Reach LAN Beyond Web Services

**Symptoms**: IoT device (192.168.0.x) can SSH to K3s node (192.168.92.x)

**Diagnosis**:
```bash
# From IoT device
ssh 192.168.92.11  # Should be blocked

# Check if web services work (should be allowed)
curl https://192.168.92.11  # Should work

# Check pfSense firewall logs
# Firewall > Logs > Firewall
```

**Solutions**:
- Verify IoT → K3s web services allow rule (ports 443, 11443) has priority 1
- Verify IoT → LAN block rule exists and comes AFTER the allow rule
- Check rule priority ordering
- Ensure rules apply to IoT interface

#### 3. WireGuard Cannot Reach Subnet

**Symptoms**: Laptop (WireGuard) cannot access 192.168.92.11

**Diagnosis**:
```bash
# From laptop
sudo wg show  # Check if tunnel is up and handshake recent
ping 10.99.0.1  # Ping pfSense WireGuard IP
ping 192.168.92.11  # Test subnet access
ip route | grep 192.168  # Verify routes installed
```

**Solutions**:
- Verify WireGuard tunnel is up: `sudo wg-quick up homelab`
- Check recent handshake: `sudo wg show` (should be < 2 min ago)
- Verify AllowedIPs in wg0.conf includes 192.168.92.0/24
- Check pfSense WireGuard interface firewall rules (allow laptop IP → LANs)
- Verify pfSense routes traffic between WireGuard interface and VLANs

#### 4. Restic Backup Fails After MinIO Migration

**Symptoms**: Backup job shows error, cannot connect to MinIO

**Diagnosis**:
```bash
# From Beelink
curl http://10.99.0.10:9000  # Test MinIO connectivity via WireGuard
ping 10.99.0.10  # Test WireGuard connectivity to MinIO
ssh beelink "systemctl status restic-backup.timer"

# From pfSense
wg show  # Verify MinIO handshake is recent (< 1 min)
```

**Solutions**:
- Verify MinIO WireGuard connection is up: check handshake on pfSense
- Check pfSense WireGuard interface firewall rules (allow LAN → MinIO:9000,9001)
- Verify restic S3 endpoint updated to `http://10.99.0.10:9000`
- Check restic environment variables for S3 credentials
- Verify MinIO persistent keepalive (25s) is configured

---

## Related Documentation

- [pfSense Integration Architecture](pfsense-integration-architecture.md) - Port forwarding and SSL setup
- [WireGuard Setup Guide](wireguard-setup.md) - Detailed WireGuard VPN configuration
- [VLAN Configuration Guide](vlan-configuration.md) - pfSense and Ubiquiti VLAN setup
- [UniFi Controller Deployment](unifi-controller-deployment.md) - Deploy controller on K3s
- [Disaster Recovery](disaster-recovery.md) - Backup and restore procedures
- [Project Structure](project-structure.md) - Overall project architecture

---

## Appendix: IP Address Allocation

### LAN VLAN (192.168.92.0/24)

| IP Address | Hostname | Device Type | Notes |
|------------|----------|-------------|-------|
| 192.168.92.1 | pfsense.local | pfSense Gateway | Static |
| 192.168.92.2 | switch.local | Ubiquiti Switch 8 | Static |
| 192.168.92.3 | ap.local | Ubiquiti AP Pro 6 | Static |
| 192.168.92.10 | - | Reserved | - |
| 192.168.92.11 | pi-cm5-1 | K3s Control Plane 1 | Static |
| 192.168.92.12 | pi-cm5-2 | K3s Control Plane 2 | Static |
| 192.168.92.13 | pi-cm5-3 | K3s Control Plane 3 | Static |
| 192.168.92.14 | beelink | K3s Worker | Static |
| 192.168.92.15-99 | - | Reserved for infrastructure | - |
| 192.168.92.100-200 | - | DHCP pool (admin devices) | Dynamic |
| 192.168.92.201-254 | - | Reserved | - |

### IoT VLAN (192.168.0.0/24)

| IP Address | Hostname | Device Type | Notes |
|------------|----------|-------------|-------|
| 192.168.0.1 | pfsense-iot | pfSense Gateway | Static |
| 192.168.0.2-99 | - | Reserved | - |
| 192.168.0.100-250 | - | DHCP pool (IoT devices) | Dynamic |
| 192.168.0.251-254 | - | Reserved | - |

### Guest VLAN (192.168.10.0/24)

| IP Address | Hostname | Device Type | Notes |
|------------|----------|-------------|-------|
| 192.168.10.1 | pfsense-guest | pfSense Gateway | Static |
| 192.168.10.2-99 | - | Reserved | - |
| 192.168.10.100-250 | - | DHCP pool (Guest devices) | Dynamic |
| 192.168.10.251-254 | - | Reserved | - |

### WireGuard VPN Network (10.99.0.0/24)

**Note**: Manually assigned static IPs for all WireGuard peers.

| WireGuard IP | Device | Type | Notes |
|--------------|--------|------|-------|
| 10.99.0.1 | pfSense | Server/Hub | Routes to 192.168.92.0/24, 192.168.0.0/24, 192.168.10.0/24 |
| 10.99.0.10 | MinIO (offsite) | Peer | S3 backup target, persistent keepalive 25s |
| 10.99.0.20 | Laptop | Client | Admin access, split tunnel |
| 10.99.0.30 | Mobile | Client | Admin access, split tunnel |

---

**End of Network Topology Documentation**
