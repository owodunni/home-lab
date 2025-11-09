# qBittorrent

BitTorrent client for downloading media content in the media stack.

## Overview

qBittorrent handles torrent downloads for the automated media pipeline. It integrates with Radarr and Sonarr for automatic content acquisition.

## Dependencies

- **Longhorn**: For persistent configuration storage
- **cert-manager**: For TLS certificates
- **Traefik**: For ingress routing
- **Media stack shared storage**: `media-stack-data` PVC (created by prerequisites)

## Configuration

### Storage

- **Config volume**: 500Mi Longhorn PVC for qBittorrent settings and database
- **Data volume**: Shared `media-stack-data` PVC (1TB) mounted at `/data`
  - `/data/torrents/movies/` - Movie downloads
  - `/data/torrents/tv/` - TV show downloads
  - `/data/torrents/incomplete/` - In-progress downloads

### Resources

- **CPU**: 100m request, 200m limit
- **Memory**: 256Mi request, 512Mi limit

### Node Placement

- **Affinity**: Runs on `beelink-1` node (where large storage is available)

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
2. **Set download paths**: Tools → Options → Downloads:
   - Default Save Path: `/data/torrents`
   - Keep incomplete in: `/data/torrents/incomplete`
3. **Create categories**:
   - Name: `movies`, Path: `/data/torrents/movies`
   - Name: `tv`, Path: `/data/torrents/tv`
4. **Configure seeding limits**: Tools → Options → BitTorrent → Seeding Limits:
   - Ratio: 2.0
   - Seeding time: 10080 minutes (7 days)

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
