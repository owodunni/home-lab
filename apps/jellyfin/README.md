# Jellyfin

Media streaming server with Intel QuickSync hardware transcoding for efficient video processing.

## Overview

Jellyfin provides a Netflix-like web interface for streaming your media library with support for:
- Hardware-accelerated transcoding (Intel QuickSync)
- Metadata fetching from TheMovieDB
- Multi-user management with viewing permissions
- Browser and mobile app streaming

## Architecture

**Image**: LinuxServer.io Jellyfin 10.10.3 (Ubuntu-based with GLIBC 2.39)
- **Why LinuxServer.io**: Official Jellyfin image uses Debian 11 (GLIBC 2.31) which is incompatible with Debian 12 host drivers required for Intel N150
- **Chart**: bjw-s/app-template v3.7.3 (supports hostPath volumes for driver mounting)

**Hardware Transcoding**:
- Intel N150 (Alder Lake-N, Gen 12) GPU with QuickSync
- VA-API iHD driver (host version May 2024)
- Low Power encoding mode (`-low_power 1`)
- Resource: `gpu.intel.com/i915: 1`

## Dependencies

**Infrastructure** (one-time setup):
1. **Beelink GPU drivers**: Run `make beelink-gpu-setup` to install Intel media drivers
2. **Helm repositories**: NFD and Intel repos added via `make k3s-helm-setup`

**Runtime Dependencies** (auto-deployed):
- **Node Feature Discovery (NFD)**: Labels nodes with GPU capabilities
- **Intel Device Plugins Operator**: Exposes GPU as Kubernetes resource
- **GpuDevicePlugin CR**: Shares GPU among up to 10 containers

**Storage**:
- **Longhorn**: Persistent config storage with automatic backups to MinIO
- **cert-manager**: TLS certificate for HTTPS ingress
- **Traefik**: Ingress routing

**Media Source**:
- **media-stack-data PVC**: Shared 1TB volume with movie/TV library

## Deployment

### Prerequisites (Auto-Deployed)

Prerequisites deploy automatically before Jellyfin via `prerequisites.yml`:
```bash
apps/jellyfin/
├── nfd/                    # Node Feature Discovery
├── gpu-plugin/             # Intel Device Plugins Operator
└── prerequisites.yml       # Deploys both automatically
```

### Deploy Jellyfin

```bash
# Full deployment (includes prerequisites)
make app-deploy APP=jellyfin
```

The deployment will:
1. Deploy NFD to label GPU-capable nodes
2. Deploy Intel GPU plugin operator
3. Create GpuDevicePlugin CR to advertise GPU
4. Deploy Jellyfin with hardware transcoding

## Hardware Transcoding Setup

### Host Configuration

**GPU Driver Mounts** (automated via values.yml):
```yaml
/dev/dri → /dev/dri                           # GPU device access
/usr/lib/x86_64-linux-gnu/dri → container     # VA-API iHD driver (May 2024)
/usr/lib/x86_64-linux-gnu/libigdgmm.so.12     # Intel Graphics Memory Management lib
```

**Why host drivers?**
Container's bundled drivers (Nov 2023) don't support Intel N150. Host drivers (May 2024) are newer and compatible.

**oneVPL Runtime Libraries** (required for QSV):
```yaml
/usr/lib/x86_64-linux-gnu → /usr/lib/jellyfin-ffmpeg/lib/onevpl-host           # oneVPL runtime (libvpl.so.2.14)
/usr/lib/x86_64-linux-gnu/libmfx-gen → /usr/lib/jellyfin-ffmpeg/lib/libmfx-gen # VPL GPU runtime (libmfx-gen.so.1.2.14)
```

**Why oneVPL libraries?**
Container's bundled oneVPL v2.15 is incompatible with host VA-API driver v25.2.3, causing h264_qsv encoder to fail with "unsupported ratecontrol mode" errors. Host oneVPL libraries (v2.14) match the VA-API driver version and enable proper QSV hardware encoding with GPU-accelerated filters (scale_qsv, vpp_qsv).

### Jellyfin UI Configuration

Navigate to: **Dashboard → Playback → Transcoding**

```
Hardware acceleration: Intel QuickSync (QSV)

QSV Device: /dev/dri/renderD128

Enable hardware decoding for:
☑ H264
☑ HEVC
☑ VP9
☑ AV1

Hardware encoding options:
☑ Enable hardware encoding
☑ Enable Intel Low-Power H.264 hardware encoder
☑ Enable Intel Low-Power HEVC hardware encoder
☑ Allow encoding in HEVC format
```

### Verification

**Check GPU usage during transcoding:**
```bash
# On beelink host (while playing video that needs transcoding)
ssh beelink
sudo intel_gpu_top

# Look for:
# Video: 97-99% (HIGH = hardware encoding working)
# Render/3D: 0-5% (should be minimal)
```

**Check ffmpeg uses hardware:**
```bash
kubectl logs -n media -l app.kubernetes.io/name=jellyfin --tail=200 | grep ffmpeg

# Should see:
# -init_hw_device vaapi=va:,vendor_id=0x8086,driver=iHD
# -codec:v:0 h264_qsv -low_power 1
```

**Performance Expectations:**
- GPU Video engine: 97-99% utilization
- CPU usage: ~30-40% (audio transcoding + HLS segmentation)
- Without hardware: CPU 80-100% (video transcoding on CPU)

## Configuration

### Storage

```yaml
config: 10Gi Longhorn PVC
  /config/data/       # SQLite database, settings
  /config/cache/      # Metadata cache
  /config/transcodes/ # HLS segments (auto-cleaned)

media: media-stack-data PVC (shared, read-only)
  /media/media/movies/ # Radarr movie library
  /media/media/tv/     # Sonarr TV library
```

### Resources

```yaml
requests:
  cpu: 200m
  memory: 512Mi
  gpu.intel.com/i915: 1  # Intel GPU allocation

limits:
  cpu: 2000m             # CPU for audio transcoding
  memory: 2Gi
  gpu.intel.com/i915: 1
```

### Node Placement

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - beelink  # Node with Intel GPU
```

## Access

- **URL**: https://jellyfin.jardoole.xyz

## Initial Setup Wizard

After first deployment, complete setup at https://jellyfin.jardoole.xyz:

### 1. Create Admin Account
- Username: (your choice)
- Password: (strong password)

### 2. Configure Hardware Transcoding
- Dashboard → Playback → Transcoding
- Follow "Hardware Transcoding Setup" section above

### 3. Add Movie Library
- Content type: Movies
- Folder: `/media/media/movies`
- Metadata: TheMovieDB, TheTVDB, OMDb

### 4. Add TV Show Library
- Content type: Shows
- Folder: `/media/media/tv`
- Metadata: TheMovieDB, TheTVDB

### 5. Generate API Key (for Jellyseerr)
- Dashboard → Advanced → API Keys → New
- Name: Jellyseerr
- Store in vault: `vault_jellyfin_api_key`

## Maintenance

### Update Version

```bash
# Edit image tag in values.yml
vim apps/jellyfin/values.yml

# Redeploy
make app-deploy APP=jellyfin
```

### Check Status

```bash
# Pod status
kubectl get pods -n media -l app.kubernetes.io/name=jellyfin

# Logs
kubectl logs -n media -l app.kubernetes.io/name=jellyfin -f

# GPU allocation
kubectl describe pod -n media -l app.kubernetes.io/name=jellyfin | grep gpu.intel.com
```

### Clean Transcode Cache

```bash
# Check disk usage
kubectl exec -n media -l app.kubernetes.io/name=jellyfin -- df -h /config

# Clear transcode cache
kubectl exec -n media -l app.kubernetes.io/name=jellyfin -- rm -rf /config/cache/transcodes/*
```

## Troubleshooting

### Videos won't play / high CPU usage

**Check hardware transcoding is enabled:**
```bash
# Verify GPU resources
kubectl describe pod -n media -l app.kubernetes.io/name=jellyfin | grep -A 5 "Limits:"

# Check ffmpeg command
kubectl logs -n media -l app.kubernetes.io/name=jellyfin --tail=200 | grep "h264_qsv\|h264_vaapi"

# Monitor GPU usage
ssh beelink
sudo intel_gpu_top  # Video engine should be 97-99% during transcode
```

**If GPU shows 0% usage:**
1. Check Jellyfin UI: Dashboard → Playback → Transcoding
2. Ensure "Intel QuickSync (QSV)" is selected
3. Enable hardware decoding for H264, HEVC, VP9
4. Force transcode: Set max bitrate to 2 Mbps in player settings

### Disk full errors

```bash
# Check space
kubectl exec -n media -l app.kubernetes.io/name=jellyfin -- df -h /config

# Clean transcodes
kubectl exec -n media -l app.kubernetes.io/name=jellyfin -- rm -rf /config/cache/transcodes/*

# Restart
kubectl rollout restart deployment/jellyfin -n media
```

### Hardware transcoding not initializing

**Check driver access:**
```bash
POD=$(kubectl get pod -n media -l app.kubernetes.io/name=jellyfin -o jsonpath='{.items[0].metadata.name}')

# Verify device readable
kubectl exec -n media $POD -- test -r /dev/dri/renderD128 && echo "✓ GPU accessible" || echo "✗ GPU not accessible"

# Check host drivers mounted
kubectl exec -n media $POD -- ls -lh /usr/lib/jellyfin-ffmpeg/lib/dri/
# Should show: iHD_drv_video.so (18MB, May 2024 timestamp)

# Verify libigdgmm library
kubectl exec -n media $POD -- ls -lh /usr/lib/x86_64-linux-gnu/libigdgmm.so.12

# Verify oneVPL libraries (required for QSV)
kubectl exec -n media $POD -- ls -lh /usr/lib/jellyfin-ffmpeg/lib/onevpl-host/ | grep libvpl
# Should show: libvpl.so.2.14 (host version, not bundled v2.15)

kubectl exec -n media $POD -- ls -lh /usr/lib/jellyfin-ffmpeg/lib/libmfx-gen/
# Should show: enctools.so (Intel VPL GPU Runtime)
```

**Test VA-API manually:**
```bash
kubectl exec -n media $POD -- /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -v verbose \
  -init_hw_device vaapi=va:/dev/dri/renderD128,driver=iHD \
  -f lavfi -i testsrc=duration=1:size=192x108 \
  -vf 'format=nv12,hwupload' -c:v h264_vaapi -f null - 2>&1 | grep -i "vaapi\|driver"

# Expected: "VAAPI driver: Intel iHD driver... va_openDriver() returns 0"
```

## Integration

**Provides media to**:
- Jellyseerr (request management interface)

**Reads media from**:
- `/media/media/movies/` (populated by Radarr)
- `/media/media/tv/` (populated by Sonarr)

## References

- [Jellyfin Documentation](https://jellyfin.org/docs/)
- [Intel Hardware Acceleration](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/intel)
- [bjw-s app-template](https://bjw-s.github.io/helm-charts/docs/app-template/)
- [Intel Device Plugins](https://intel.github.io/intel-device-plugins-for-kubernetes/)
