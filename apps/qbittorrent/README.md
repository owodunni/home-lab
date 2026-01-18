# qBittorrent

BitTorrent client for downloading media content in the media stack.

## Overview

qBittorrent handles torrent downloads for the automated media pipeline. It integrates with Radarr and Sonarr for automatic content acquisition.

## Dependencies

- **hostPath storage (on beelink)
- **cert-manager**: For TLS certificates
- **Traefik**: For ingress routing
- **Media stack shared storage**: `media-stack-data` PVC (created by prerequisites)

## Configuration

### Storage

- **Config volume**: 500Mi hostPath volume for qBittorrent settings and database
- **Data volume**: Shared `media-stack-data` PVC (1TB) mounted at `/data`
  - `/data/torrents/movies/` - Movie downloads
  - `/data/torrents/tv/` - TV show downloads
  - `/data/torrents/incomplete/` - In-progress downloads

### Resources

- **CPU**: 100m request, 200m limit
- **Memory**: 256Mi request, 512Mi limit

### Node Placement

- **Affinity**: Runs on `beelink-1` node (where large storage is available)

### VPN Configuration

qBittorrent is configured with ProtonVPN via Gluetun sidecar for privacy and security.

**Architecture**:
- **Gluetun sidecar**: Establishes OpenVPN tunnel to ProtonVPN
- **Port-manager sidecar**: Automatically updates qBittorrent listening port when VPN assigns new forwarded port
- **Shared networking**: All qBittorrent traffic routes through VPN tunnel

**Configuration**:
- Protocol: OpenVPN (more reliable port forwarding than WireGuard)
- Provider: ProtonVPN
- Server: Sweden
- Port forwarding: Enabled (NAT-PMP)
- DNS: Quad9 (9.9.9.9)
- Resources: +260m CPU, +384Mi memory for sidecars
- Health check: 120s initial delay for VPN connection

**Credentials**:
- Managed via ansible-vault: `vault_protonvpn_username`, `vault_protonvpn_password`, `vault_qbittorrent_password`
- Deployed as Kubernetes Secrets: `protonvpn-secret`, `qbittorrent-secret` in media namespace
- OpenVPN username must include `+pmp` suffix for port forwarding

## Deployment

```bash
make app-deploy APP=qbittorrent
```

## Access

- **URL**: https://qbittorrent.jardoole.xyz
- **Default credentials**: admin / adminadmin

## Initial Setup

After deployment, configure qBittorrent via web UI:

1. **Change password**: Tools → Options → Web UI → Authentication
2. **Enable localhost bypass**: Tools → Options → Web UI → Authentication
   - ✅ Check "Bypass authentication for clients on localhost"
   - **Required** for automatic port updates via port-manager sidecar
3. **Set download paths**: Tools → Options → Downloads:
   - Default Save Path: `/data/torrents`
   - Keep incomplete in: `/data/torrents/incomplete`
4. **Create categories**:
   - Name: `movies`, Path: `/data/torrents/movies`
   - Name: `tv`, Path: `/data/torrents/tv`
5. **Configure seeding limits**: Tools → Options → BitTorrent → Seeding Limits:
   - Ratio: 2.0
   - Seeding time: 10080 minutes (7 days)

## VPN Verification

After deployment, verify VPN connectivity:

### 1. Check Gluetun Connection

```bash
# View Gluetun logs
kubectl logs -n media deployment/qbittorrent -c gluetun --tail=50

# Look for successful connection:
# "ip getter: Public IP address is 123.45.67.89 (Sweden)"
# "port forwarding: port forwarded is 12345"
```

### 2. Verify IP Address

```bash
# Check public IP through VPN
kubectl exec -n media deployment/qbittorrent -c app -- \
  wget -qO- https://ifconfig.me

# Should show ProtonVPN IP (not your home IP)
```

### 3. Confirm Port Forwarding

In qBittorrent web UI:
1. Tools → Options → Connection
2. **Listening Port** should show VPN-assigned port (not 6881)
3. Port should update automatically when VPN reassigns

### 4. Test with Torrent

Add a legal test torrent (Ubuntu ISO) and verify:
- Seeds/peers connect successfully
- Upload/download speeds are functional
- Tracker shows VPN IP, not home IP

## Integration

**Used by**:
- Radarr (movie downloads)
- Sonarr (TV show downloads)

**Connection details** (for Radarr/Sonarr):
- Host: `qbittorrent.media.svc.cluster.local`
- Port: `8080`
- Username: `admin`
- Password: (configured in web UI)

## Maintenance

### Update Version

1. Edit `Chart.yml` or `values.yml` to change image tag
2. Redeploy: `make app-deploy APP=qbittorrent`

### Check Status

```bash
kubectl get pods -n media -l app.kubernetes.io/name=qbittorrent
kubectl logs -n media deployment/qbittorrent -f
```

### Clear Download Queue

If downloads are stuck:
1. Open web UI
2. Right-click downloads → Delete
3. Radarr/Sonarr will re-attempt download

## Troubleshooting

### VPN Connection Issues

**Symptom**: qBittorrent shows no peers/seeds, or pod fails to start

**Check Gluetun status**:
```bash
kubectl logs -n media deployment/qbittorrent -c gluetun --tail=100

# Look for errors like:
# "authentication failed"
# "port forwarding: ... connection refused - make sure you have +pmp at the end of your OpenVPN username"
```

**Common causes**:
1. **Missing +pmp suffix**: OpenVPN username must end with `+pmp` for port forwarding
2. **Invalid credentials**: Verify `vault_protonvpn_username` and `vault_protonvpn_password` in ansible-vault
3. **ProtonVPN account issue**: Check account status at account.protonvpn.com
4. **Network connectivity**: Verify control plane can reach ProtonVPN endpoints

**Fix**:
```bash
# Restart pod to retry VPN connection
kubectl rollout restart deployment/qbittorrent -n media

# Check Secrets are deployed correctly
kubectl get secret protonvpn-secret -n media -o yaml
kubectl get secret qbittorrent-secret -n media -o yaml
```

### Port Forwarding Not Working

**Symptom**: Listening port stays at 6881 or shows error in connection test

**Check port-manager logs**:
```bash
kubectl logs -n media deployment/qbittorrent -c port-manager --tail=50

# Look for:
# "Port forward file exists: /tmp/gluetun/forwarded_port"
# "Updated qBittorrent port to: 12345"
```

**Common causes**:
1. **Localhost auth not bypassed**: port-manager requires "Bypass authentication for clients on localhost" enabled in qBittorrent Web UI
2. **VPN not connected**: Port forwarding requires active VPN connection
3. **Shared volume issue**: /tmp/gluetun volume not mounted correctly
4. **IP banned**: Too many failed auth attempts banned localhost IP

**Fix**:
```bash
# Check forwarded port file exists
kubectl exec -n media deployment/qbittorrent -c gluetun -- cat /tmp/gluetun/forwarded_port

# Check if localhost can access API
kubectl exec -n media deployment/qbittorrent -c app -- curl -s http://localhost:8080/api/v2/app/version

# If banned or forbidden, enable localhost bypass in Web UI:
# Tools → Options → Web UI → Authentication → ✅ Bypass authentication for clients on localhost
```

### Pod Stuck in CrashLoopBackOff

**Symptom**: qBittorrent pod restarts repeatedly

**Check all container logs**:
```bash
# Check which container is failing
kubectl describe pod -n media -l app.kubernetes.io/name=qbittorrent

# Check app container
kubectl logs -n media deployment/qbittorrent -c app --tail=50

# Check gluetun container
kubectl logs -n media deployment/qbittorrent -c gluetun --tail=50

# Check port-manager container
kubectl logs -n media deployment/qbittorrent -c port-manager --tail=50
```

**Common causes**:
1. **Gluetun capability missing**: Requires NET_ADMIN and SYS_MODULE capabilities
2. **Resource limits**: Increase pod memory if OOMKilled
3. **VPN authentication failure**: Check ProtonVPN credentials

### Downloads stuck at 0%

**Check network connectivity**:
```bash
kubectl exec -n media deployment/qbittorrent -- ping -c 3 1.1.1.1
```

**Check disk space**:
```bash
kubectl exec -n media deployment/qbittorrent -- df -h /data
```

### Can't access web UI

**Check ingress**:
```bash
kubectl get ingress -n media
kubectl describe ingress qbittorrent -n media
```

**Check certificate**:
```bash
kubectl get certificate -n media
```

## References

- [qBittorrent Documentation](https://github.com/qbittorrent/qBittorrent/wiki)
- [LinuxServer.io qBittorrent Image](https://docs.linuxserver.io/images/docker-qbittorrent)
- [TRaSH Guides - Download Client Setup](https://trash-guides.info/Downloaders/qBittorrent/)
- [Gluetun VPN Client](https://github.com/qdm12/gluetun)
- [ProtonVPN OpenVPN Setup](https://protonvpn.com/support/linux-openvpn/)
- [Gluetun qBittorrent Port Manager](https://github.com/SnoringDragon/gluetun-qbittorrent-port-manager)
