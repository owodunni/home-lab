# Sonarr

TV show collection manager with automatic episode download and quality upgrade capabilities.

## Overview

Sonarr monitors TV show releases and automatically searches for, downloads, and organizes episodes. Integrates with Prowlarr for indexer management and qBittorrent for downloads.

## Dependencies

- **Longhorn**: For persistent configuration storage
- **cert-manager**: For TLS certificates
- **Traefik**: For ingress routing
- **Media stack shared storage**: `media-stack-data` PVC (created by prerequisites)
- **Prowlarr**: For indexer management
- **qBittorrent**: For torrent downloads

## Configuration

### Storage

- **Config volume**: 1Gi Longhorn PVC for Sonarr database and settings
- **Data volume**: Shared `media-stack-data` PVC mounted at `/data`
  - `/data/media/tv/` - TV show library (root folder)
  - `/data/torrents/tv/` - Download destination

### Resources

- **CPU**: 50m request, 100m limit
- **Memory**: 128Mi request, 256Mi limit

### Node Placement

- **Affinity**: Runs on `beelink-1` node (where shared media storage is available)

## Deployment

```bash
make app-deploy APP=sonarr
```

## Access

- **URL**: https://sonarr.jardoole.xyz

## Initial Setup

After deployment, configure Sonarr via web UI (https://sonarr.jardoole.xyz):

### 1. Media Management

- Settings → Media Management → Root Folders → Add Root Folder
  - Path: `/data/media/tv`
- Settings → Media Management → File Management
  - **Enable "Use Hardlinks instead of Copy"** (CRITICAL for storage efficiency)

### 2. Download Client

- Settings → Download Clients → Add → qBittorrent
  - Host: `qbittorrent.media.svc.cluster.local`
  - Port: `8080`
  - Username: `admin`
  - Password: (from qBittorrent web UI)
  - Category: `tv`
  - Test → Save

### 3. Indexers (Prowlarr Integration)

- Settings → Indexers → Add → Prowlarr
  - Prowlarr Server: `http://prowlarr.media.svc.cluster.local:9696`
  - API Key: `{{ vault_prowlarr_api_key }}`
  - Sync Level: `Full Sync`
  - Test → Save

### 4. Quality Profile

- Settings → Profiles → Edit "HD-1080p"
  - Enable: 1080p Bluray/WEB
  - Disable: 4K (Pi hardware limitation)

### 5. Note API Key

- Settings → General → Security → API Key
- Save to vault: `vault_sonarr_api_key`

## Integration

**Used by**:
- Jellyseerr (for TV show requests)

**Uses**:
- Prowlarr (indexer sync)
- qBittorrent (downloads)

## Maintenance

### Update Version

1. Edit `values.yml` to change image tag
2. Redeploy: `make app-deploy APP=sonarr`

### Check Status

```bash
kubectl get pods -n media -l app.kubernetes.io/name=sonarr
kubectl logs -n media deployment/sonarr -f
```

### Monitor Queue

Web UI → Activity → Queue (shows active downloads)

## Troubleshooting

### Episodes not downloading

**Check indexers**:
- Settings → Indexers (ensure synced from Prowlarr)
- System → Tasks → Search Indexers

**Check download client**:
- Settings → Download Clients → Test connection
- Verify qBittorrent credentials

### Hardlinks not working

**Verify config**:
```bash
kubectl exec -n media deployment/sonarr -- ls -li /data/torrents/tv/
kubectl exec -n media deployment/sonarr -- ls -li /data/media/tv/
# Compare inode numbers - should match
```

**If not working**:
- Settings → Media Management → File Management
- Ensure "Use Hardlinks instead of Copy" is enabled

### Can't access web UI

**Check ingress**:
```bash
kubectl get ingress -n media
kubectl describe ingress sonarr -n media
```

## References

- [Sonarr Documentation](https://wiki.servarr.com/sonarr)
- [LinuxServer.io Sonarr Image](https://docs.linuxserver.io/images/docker-sonarr)
- [TRaSH Guides - Sonarr](https://trash-guides.info/Sonarr/)
