# Jellyseerr

User-friendly request management system for Jellyfin with Overseerr-like interface.

## Overview

Jellyseerr provides a beautiful interface for users to request movies and TV shows. It integrates with Jellyfin for authentication and library sync, and Radarr/Sonarr for automated downloads.

## Dependencies

- **Longhorn**: For persistent configuration storage
- **cert-manager**: For TLS certificates
- **Traefik**: For ingress routing
- **Jellyfin**: For authentication and library information
- **Radarr**: For movie requests
- **Sonarr**: For TV show requests

## Configuration

### Storage

- **Config volume**: 500Mi Longhorn PVC for Jellyseerr database and settings

### Resources

- **CPU**: 50m request, 100m limit
- **Memory**: 128Mi request, 256Mi limit

### Node Placement

- **Affinity**: Runs on `beelink-1` node

## Deployment

```bash
make app-deploy APP=jellyseerr
```

## Access

- **URL**: https://jellyseerr.jardoole.xyz

## Initial Setup

After deployment, complete the setup wizard at https://jellyseerr.jardoole.xyz:

### 1. Connect to Jellyfin

- Server URL: `http://jellyfin.media.svc.cluster.local:8096`
- API Key: `{{ vault_jellyfin_api_key }}`
- Connect and sign in with your Jellyfin admin account
- Sync libraries

### 2. Connect to Radarr

- Settings → Services → Radarr → Add Server
- Server URL: `http://radarr.media.svc.cluster.local:7878`
- API Key: `{{ vault_radarr_api_key }}`
- Quality Profile: `HD-1080p`
- Root Folder: `/data/media/movies`
- Test → Save

### 3. Connect to Sonarr

- Settings → Services → Sonarr → Add Server
- Server URL: `http://sonarr.media.svc.cluster.local:8989`
- API Key: `{{ vault_sonarr_api_key }}`
- Quality Profile: `HD-1080p`
- Root Folder: `/data/media/tv`
- Anime Quality Profile: (none)
- Test → Save

### 4. Configure User Permissions

- Settings → Users
- Configure request limits (optional)
- Enable auto-approve for trusted users (optional)

## Integration

**Authenticates with**:
- Jellyfin (user management)

**Sends requests to**:
- Radarr (movie downloads)
- Sonarr (TV downloads)

## Usage

### Request a Movie or TV Show

1. Search for content in the main interface
2. Click "Request"
3. Request shows up in "Requests" tab
4. Radarr/Sonarr automatically starts download
5. Status updates to "Available" when in Jellyfin library

### Monitor Requests

- Requests tab shows all pending/approved/available requests
- Click request for details and status

## Maintenance

### Update Version

1. Edit `values.yml` to change image tag
2. Redeploy: `make app-deploy APP=jellyseerr`

### Check Status

```bash
kubectl get pods -n media -l app.kubernetes.io/name=jellyseerr
kubectl logs -n media deployment/jellyseerr -f
```

## Troubleshooting

### Can't connect to Jellyfin

**Check service connectivity**:
```bash
kubectl exec -n media deployment/jellyseerr -- nslookup jellyfin.media.svc.cluster.local
```

**Verify Jellyfin API key**:
- Check Jellyfin: Dashboard → Advanced → API Keys
- Ensure key matches Jellyseerr configuration

### Can't connect to Radarr/Sonarr

**Check service names**:
- Radarr: `http://radarr.media.svc.cluster.local:7878`
- Sonarr: `http://sonarr.media.svc.cluster.local:8989`

**Verify API keys**:
- Radarr: Settings → General → Security → API Key
- Sonarr: Settings → General → Security → API Key
- Ensure keys match Jellyseerr configuration

**Test connection**:
- Settings → Services → Test (button next to each service)

### Requests not processing

**Check Radarr/Sonarr queue**:
- Open Radarr/Sonarr web UI
- Activity → Queue
- Verify downloads are starting

**Check logs**:
```bash
kubectl logs -n media deployment/jellyseerr -f
```

### Can't access web UI

**Check ingress**:
```bash
kubectl get ingress -n media
kubectl describe ingress jellyseerr -n media
```

**Check certificate**:
```bash
kubectl get certificate -n media
```

## References

- [Jellyseerr GitHub](https://github.com/Fallenbagel/jellyseerr)
- [Jellyseerr Documentation](https://github.com/Fallenbagel/jellyseerr/wiki)
- [Overseerr Documentation](https://docs.overseerr.dev/) (similar UI/workflow)
