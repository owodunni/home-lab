## Prowlarr

Centralized indexer and torrent tracker manager for Radarr and Sonarr.

## Overview

Prowlarr manages indexers and torrent trackers in one place, syncing them to Radarr and Sonarr automatically. This eliminates the need to configure indexers separately in each *arr app.

## Dependencies

- **Longhorn**: For persistent configuration storage
- **cert-manager**: For TLS certificates
- **Traefik**: For ingress routing
- **Media stack shared storage**: `media-stack-data` PVC (created by prerequisites)

## Configuration

### Storage

- **Config volume**: 500Mi Longhorn PVC for Prowlarr settings and database

### Resources

- **CPU**: 25m request, 50m limit
- **Memory**: 64Mi request, 128Mi limit

### Node Placement

- **Affinity**: Runs on `beelink-1` node

## Deployment

```bash
make app-deploy APP=prowlarr
```

## Access

- **URL**: https://prowlarr.jardoole.xyz

## Initial Setup

After deployment, configure Prowlarr via web UI:

1. **Add indexers**: Settings → Indexers → Add Indexers
   - Add public torrent indexers (1337x, The Pirate Bay, YTS, EZTV, etc.)
   - Test each indexer before saving
2. **Note API key**: Settings → General → Security → API Key
   - Save to vault: `vault_prowlarr_api_key`

## Integration

**Syncs to**:
- Radarr (movie indexers)
- Sonarr (TV indexers)

**Connection details** (for Radarr/Sonarr):
- Prowlarr Server: `http://prowlarr.media.svc.cluster.local:9696`
- API Key: (from Settings → General → Security)

**Apps Configuration** (in Prowlarr):
- Settings → Apps → Add → Radarr
  - Prowlarr Server: `http://radarr.media.svc.cluster.local:7878`
  - API Key: `{{ vault_radarr_api_key }}`
  - Sync Level: `Full Sync`
- Settings → Apps → Add → Sonarr
  - Prowlarr Server: `http://sonarr.media.svc.cluster.local:8989`
  - API Key: `{{ vault_sonarr_api_key }}`
  - Sync Level: `Full Sync`

## Maintenance

### Update Version

1. Edit `values.yml` to change image tag
2. Redeploy: `make app-deploy APP=prowlarr`

### Check Status

```bash
kubectl get pods -n media -l app.kubernetes.io/name=prowlarr
kubectl logs -n media deployment/prowlarr -f
```

### Test Indexers

In Prowlarr web UI:
- System → Tasks → Search Indexers
- Verify results appear

## Troubleshooting

### Indexers not syncing to Radarr/Sonarr

**Check app connections**:
- Settings → Apps → Test connection
- Verify API keys match

**Check indexer health**:
- Indexers → Test All
- Disable broken indexers

### Can't access web UI

**Check ingress**:
```bash
kubectl get ingress -n media
kubectl describe ingress prowlarr -n media
```

**Check certificate**:
```bash
kubectl get certificate -n media
```

## References

- [Prowlarr Documentation](https://wiki.servarr.com/prowlarr)
- [LinuxServer.io Prowlarr Image](https://docs.linuxserver.io/images/docker-prowlarr)
- [TRaSH Guides - Prowlarr Setup](https://trash-guides.info/Prowlarr/)
