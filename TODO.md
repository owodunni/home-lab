# TODO - Home Lab Tasks

**Last Updated**: 2025-11-21

---

## Current Projects

### ✅ Completed: Media Stack Deployment

- 6 apps running (Jellyfin, Jellyseerr, Radarr, Sonarr, Prowlarr, qBittorrent)
- Intel QuickSync hardware transcoding enabled
- End-to-end workflow tested

**Docs**: `docs/media-stack-complete-guide.md`

### 🔄 In Progress: Network Migration

**Goal**: Multi-VLAN segmentation + WireGuard VPN for remote access + offsite MinIO

**Current**: Single flat network (192.168.0.0/24)
**Target**: 3 VLANs (LAN/IoT/Guest) + WireGuard VPN + MinIO offsite

**Docs**: `docs/network-topology.md`, `docs/wireguard-setup.md`

---

## Quick Reference

### Access URLs
- Jellyfin: https://jellyfin.jardoole.xyz
- Longhorn: https://longhorn.jardoole.xyz
- (All apps): https://{app}.jardoole.xyz

### Commands
```bash
kubectl get pods -n media          # Pod status
kubectl logs -n media deploy/{app} # App logs
wg show                            # WireGuard status
```

### Docs
- **Network**: `docs/network-topology.md`
- **WireGuard**: `docs/wireguard-setup.md`
- **Media Stack**: `docs/media-stack-complete-guide.md`
- **App Deploy**: `docs/app-deployment-guide.md`

---

## ⚠️ CRITICAL: Backup Testing (Do First!)

**Must complete BEFORE network changes**

- [ ] Test PVC restore (Longhorn → delete prowlarr-config → restore → verify)
- [ ] Document cluster state snapshot (save to vault_passwords/)
- [ ] Verify Longhorn backup schedule active (daily 2am, weekly Sun 3am)

---

## Network Migration Phases

### Phase 0 & 1: Documentation (~2 hours)

📖 **Ref**: [docs/network-topology.md#implementation-phases](docs/network-topology.md#implementation-phases)

- [x] Create network topology docs
- [x] Create WireGuard setup guide
- [ ] Create VLAN configuration guide (`docs/vlan-configuration.md`)
- [ ] Create UniFi Controller deployment guide (`docs/unifi-controller-deployment.md`)
- [ ] Update pfSense integration docs (add WireGuard section)
- [ ] Update project structure docs (add network architecture)
- [ ] Create network variables in `group_vars/all/network.yml`

---

### Phase 2: WireGuard Key Generation (~15 min)

📖 **Ref**: [docs/wireguard-setup.md#part-1](docs/wireguard-setup.md#part-1-generate-wireguard-keys)

- [ ] Install wireguard-tools
- [ ] Generate 4 keypairs (pfSense, MinIO, laptop, phone)
- [ ] Save private keys to `vault_passwords/wireguard-*-private.key`
- [ ] Encrypt private keys with ansible-vault
- [ ] Keep public keys in `~/wireguard-keys/` for Phase 11

---

### Phase 3: UniFi Controller Deploy (~1 hour)

📖 **Ref**: Phase 1 docs (to be created)

- [ ] Create Helm chart in `apps/unifi-controller/`
- [ ] Deploy: `make app-deploy APP=unifi-controller`
- [ ] Complete setup wizard at https://unifi.jardoole.xyz
- [ ] Configure auto-backup
- [ ] Save admin credentials to vault_passwords/

---

### Phase 4: Hardware Prep (~30 min)

- [ ] Setup pfSense console access (keyboard + monitor)
- [ ] Backup pfSense config (save to vault_passwords/)
- [ ] Screenshot switch/AP config from UniFi Controller
- [ ] Verify physical access to all hardware

---

### Phase 5: Adopt Switch & AP (~1 hour)

📖 **Ref**: UniFi docs (to be created)

- [ ] Factory reset switch (if needed)
- [ ] Adopt switch via UniFi Controller
- [ ] Adopt AP via UniFi Controller
- [ ] Set switch static IP: 192.168.0.2
- [ ] Set AP static IP: 192.168.0.3
- [ ] Backup UniFi config (save to vault_passwords/)

---

### Phase 6: VLAN Configuration (~2 hours) ⚠️ HIGH RISK

📖 **Ref**: [docs/network-topology.md#phase-2](docs/network-topology.md#phase-2-vlan-configuration)

**pfSense console access required**

- [ ] Create LAN VLAN 1 (192.168.92.1/24) + DHCP
- [ ] Create IoT VLAN 10 (192.168.0.1/24) + DHCP
- [ ] Create Guest VLAN 20 (192.168.10.1/24) + DHCP
- [ ] Verify all 3 gateways reachable from pfSense

---

### Phase 7: Update K3s IPs (~1 hour) ⚠️ Services briefly down

📖 **Ref**: Use netplan to change IPs

- [ ] pi-cm5-1: 192.168.0.11 → 192.168.92.11
- [ ] pi-cm5-2: 192.168.0.12 → 192.168.92.12
- [ ] pi-cm5-3: 192.168.0.13 → 192.168.92.13
- [ ] beelink: 192.168.0.14 → 192.168.92.14
- [ ] Verify K3s cluster: `kubectl get nodes` (all Ready)
- [ ] Update Ansible inventory `hosts.ini`

---

### Phase 8: Switch VLAN Config (~1 hour) ⚠️ HIGH RISK

📖 **Ref**: [docs/network-topology.md#switch-port-configuration](docs/network-topology.md#switch-port-configuration)

**UniFi Controller**

- [ ] Create 3 VLAN networks (LAN, IoT, Guest)
- [ ] Port 1 (pfSense): Trunk, all VLANs
- [ ] Ports 2-5 (K3s nodes): Access, LAN VLAN
- [ ] Port 6 (AP): Trunk, all VLANs
- [ ] Apply & verify K3s cluster still up

---

### Phase 9: Multi-SSID WiFi (~1 hour)

📖 **Ref**: [docs/network-topology.md#phase-3](docs/network-topology.md#phase-3-multi-ssid-wifi)

**UniFi Controller**

- [ ] Create "HomeNetwork" SSID → LAN VLAN (WPA3)
- [ ] Create "SmartHome" SSID → IoT VLAN (WPA2)
- [ ] Create "Guest" SSID → Guest VLAN (WPA2, isolated)
- [ ] Test laptop on HomeNetwork (gets 192.168.92.x, can SSH to K3s)
- [ ] Test IoT device on SmartHome (gets 192.168.0.x)
- [ ] Test guest on Guest (gets 192.168.10.x)
- [ ] Migrate all devices to correct SSIDs
- [ ] Disable old SSID

---

### Phase 10: Firewall Rules (~2 hours) ⚠️ RULE ORDER MATTERS

📖 **Ref**: [docs/network-topology.md#firewall-rules](docs/network-topology.md#firewall-rules)

**LAN VLAN Rules**
- [ ] Allow LAN → IoT (admin access)
- [ ] Allow LAN → Guest (admin access)
- [ ] Allow LAN → Internet

**IoT VLAN Rules** (order critical!)
- [ ] Allow IoT → K3s (192.168.92.11-14) ports 443,11443 (web services)
- [ ] Block IoT → LAN net (all other traffic)
- [ ] Block IoT → Guest net
- [ ] Block IoT → pfSense (443,80,22)
- [ ] Allow IoT → Any port 53 (DNS)
- [ ] Allow IoT → Any ports 80,443 (internet)

**Guest VLAN Rules**
- [ ] Block Guest → LAN
- [ ] Block Guest → IoT
- [ ] Block Guest → pfSense
- [ ] Allow Guest → DNS + Internet

**Testing**
- [ ] IoT CAN access Jellyfin
- [ ] IoT CANNOT SSH to K3s
- [ ] Guest CANNOT access Jellyfin
- [ ] Monitor logs for 24h

---

### Phase 11: WireGuard VPN (~1.5 hours)

📖 **Ref**: [docs/wireguard-setup.md](docs/wireguard-setup.md)

**pfSense Server**
- [ ] Create WireGuard tunnel (10.99.0.1/24, port 51820)
- [ ] Enable WireGuard interface
- [ ] WAN rule: Allow UDP 51820
- [ ] WireGuard interface rules: Allow laptop/phone (10.99.0.20,30) → Any, Block MinIO (10.99.0.10) → Any
- [ ] LAN rule: Allow LAN → MinIO:9000-9001

**MinIO Peer**
- [ ] Add MinIO peer in pfSense (10.99.0.10/32, persistent keepalive 25s)
- [ ] Install WireGuard on MinIO: `sudo apt install wireguard wireguard-tools`
- [ ] Create `/etc/wireguard/wg0.conf` (see guide for template)
- [ ] Start: `sudo systemctl enable --now wg-quick@wg0`
- [ ] Verify handshake: `sudo wg show`

**Laptop Client**
- [ ] Add laptop peer in pfSense (10.99.0.20/32)
- [ ] Install WireGuard: `sudo apt install wireguard`
- [ ] Create `/etc/wireguard/homelab.conf` (split tunnel config)
- [ ] Test: `sudo wg-quick up homelab`
- [ ] Verify SSH works: `ssh pi@192.168.92.11`
- [ ] Verify split tunnel: `curl ifconfig.me` (shows laptop IP)

**Phone Client**
- [ ] Add phone peer in pfSense (10.99.0.30/32)
- [ ] Install WireGuard app
- [ ] Generate QR code on laptop: `qrencode -t ansiutf8 < phone.conf`
- [ ] Scan QR in app, test connection

---

### Phase 12: MinIO Migration (~3 hours) ⚠️ Backups fail during move

📖 **Ref**: [docs/network-topology.md#phase-6](docs/network-topology.md#phase-6-minio-migration)

- [ ] Update Longhorn backup target: `http://10.99.0.10:9000`
- [ ] Test backup via WireGuard (while MinIO still local)
- [ ] Document MinIO WireGuard connection info (save to vault_passwords/)
- [ ] Physically transport MinIO offsite
- [ ] Verify WireGuard connection from offsite
- [ ] Test MinIO S3 access: `curl http://10.99.0.10:9000`
- [ ] Trigger full Longhorn backup suite
- [ ] Port scan from internet (verify 9000/9001 closed)
- [ ] Document offsite location details

---

### Phase 13: Validation (~4 hours)

📖 **Ref**: [docs/network-topology.md#phase-7](docs/network-topology.md#phase-7-validation--documentation)

**Testing**
- [ ] Test PVC restore from offsite MinIO
- [ ] Verify IoT isolation (can access Jellyfin, cannot SSH)
- [ ] Verify Guest isolation (cannot access LAN/IoT)
- [ ] Verify MinIO isolation (cannot access cluster)
- [ ] Port scan pfSense (only 443 & 51820 open)
- [ ] Measure WireGuard throughput: `iperf3 -c 10.99.0.10`

**Documentation**
- [ ] Update docs/disaster-recovery.md
- [ ] Update docs/pfsense-integration-architecture.md
- [ ] Update docs/project-structure.md
- [ ] Create docs/runbooks/add-wireguard-peer.md
- [ ] Create docs/runbooks/onboard-iot-device.md
- [ ] Create docs/runbooks/troubleshoot-vlan-issues.md
- [ ] Update README.md
- [ ] Create network architecture diagram

---

### Phase 14: Ongoing Monitoring

**Daily**
- [ ] Check Longhorn backup status
- [ ] Review pfSense firewall logs

**Weekly**
- [ ] Verify WireGuard peer handshakes (MinIO < 1 min ago)
- [ ] Test MinIO reachability: `ping 10.99.0.10`
- [ ] Test random PVC restore

**Monthly**
- [ ] Review WireGuard firewall rules
- [ ] Audit IoT device list
- [ ] Update WireGuard clients

**Quarterly**
- [ ] Full disaster recovery drill
- [ ] Review firewall rules
- [ ] Network security review

**Annual**
- [ ] Audit network topology docs
- [ ] Rotate WireGuard keys

---

## Post-Migration Reference

### Critical IPs

| Device | IP | VLAN | Access |
|--------|-----|------|--------|
| pfSense LAN | 192.168.92.1 | 1 | https://192.168.92.1 |
| pfSense IoT | 192.168.0.1 | 10 | Gateway |
| pfSense Guest | 192.168.10.1 | 20 | Gateway |
| Switch | 192.168.92.2 | 1 | Via UniFi |
| AP | 192.168.92.3 | 1 | Via UniFi |
| pi-cm5-1/2/3 | 192.168.92.11-13 | 1 | SSH |
| beelink | 192.168.92.14 | 1 | SSH |
| MinIO | 10.99.0.10 | WG | http://10.99.0.10:9001 |

### WiFi SSIDs

| SSID | VLAN | Subnet | Purpose |
|------|------|--------|---------|
| HomeNetwork | 1 | 192.168.92.0/24 | Trusted devices |
| SmartHome | 10 | 192.168.0.0/24 | IoT devices |
| Guest | 20 | 192.168.10.0/24 | Guests |

### Useful Commands

```bash
# WireGuard
wg show                            # Status & handshakes
sudo wg-quick up homelab           # Connect VPN

# K3s
kubectl get nodes                  # Cluster health
kubectl get pods -n media          # Media stack
kubectl logs -n longhorn-system -l app=longhorn-backup-controller

# Verify split tunnel
ip route | grep 192.168            # Should show VPN routes
curl ifconfig.me                   # Should show local IP (not home)
```

---

## Success Criteria

✅ VLANs operational (LAN/IoT/Guest)
✅ WiFi SSIDs working (HomeNetwork/SmartHome/Guest)
✅ Firewall rules enforced
✅ WireGuard VPN running
✅ MinIO offsite via WireGuard (persistent keepalive working)
✅ Longhorn backups succeeding
✅ PVC restore tested
✅ Remote access working (laptop/phone)
✅ Documentation complete
✅ No service degradation

**Migration complete!** 🎉
