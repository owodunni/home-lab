# Jellyfin

Netflix-like media streaming server for movies and TV shows.

## Overview

Jellyfin provides a beautiful web interface for streaming your media library with support for transcoding, metadata fetching, and multi-user management.

## Dependencies

- **Longhorn**: For persistent configuration and cache storage
- **cert-manager**: For TLS certificates
- **Traefik**: For ingress routing
- **Media stack shared storage**: `media-stack-data` PVC (created by prerequisites)

## Configuration

### Storage

- **Config volume**: 2Gi Longhorn PVC for Jellyfin database and settings
- **Cache volume**: 5Gi Longhorn PVC for transcoding cache (not backed up)
- **Media volume**: Shared `media-stack-data` PVC mounted read-only at `/data`
  - `/data/media/movies/` - Movie library
  - `/data/media/tv/` - TV show library

### Resources

- **CPU**: 250m request, 500m limit (transcoding may need more)
- **Memory**: 256Mi request, 512Mi limit

### Node Placement

- **Affinity**: Runs on `beelink-1` node (where media storage is available)

## Deployment

```bash
make app-deploy APP=jellyfin
```

## Access

- **URL**: https://jellyfin.jardoole.xyz

## Initial Setup

After deployment, complete the setup wizard at https://jellyfin.jardoole.xyz:

### 1. Create Admin Account

- Username: (your choice)
- Password: (strong password)

### 2. Add Movie Library

- Content type: Movies
- Display name: Movies
- Folder: `/data/media/movies`
- Enable metadata providers:
  - TheMovieDB
  - TheTVDB
  - Open Movie Database

### 3. Add TV Show Library

- Content type: Shows
- Display name: TV Shows
- Folder: `/data/media/tv`
- Enable metadata providers:
  - TheMovieDB
  - TheTVDB

### 4. Create User Accounts

- Dashboard → Users → Add User
- Configure viewing permissions per user

### 5. Note API Key (for Jellyseerr)

- Dashboard → Advanced → API Keys → New API Key
- Name: Jellyseerr
- Save to vault: `vault_jellyfin_api_key`

## Integration

**Used by**:
- Jellyseerr (request management)

**Reads from**:
- `/data/media/` (populated by Radarr/Sonarr)

## Maintenance

### Update Version

1. Edit `values.yml` to change image tag
2. Redeploy: `make app-deploy APP=jellyfin`

### Check Status

```bash
kubectl get pods -n media -l app.kubernetes.io/name=jellyfin
kubectl logs -n media deployment/jellyfin -f
```

### Scan Library

Web UI → Dashboard → Scan Library (refresh metadata)

## Troubleshooting

### Videos won't play

**Check file permissions**:
```bash
kubectl exec -n media deployment/jellyfin -- ls -lh /data/media/movies/
# Files should be readable (644 or 755)
```

**Try Direct Play**:
- Playback Settings → Disable transcoding
- H.264 works on all devices, H.265 may require transcoding

### Transcoding errors

**Check logs**:
```bash
kubectl logs -n media deployment/jellyfin | grep -i transcode
```

**Check cache space**:
```bash
kubectl exec -n media deployment/jellyfin -- df -h /cache
```

### Can't access web UI

**Check ingress**:
```bash
kubectl get ingress -n media
kubectl describe ingress jellyfin -n media
```

**Check certificate**:
```bash
kubectl get certificate -n media
```

## References

- [Jellyfin Documentation](https://jellyfin.org/docs/)
- [Jellyfin Helm Chart](https://github.com/jellyfin/jellyfin-helm)
- [Hardware Acceleration](https://jellyfin.org/docs/general/administration/hardware-acceleration.html)
