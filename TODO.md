# TODO - Media Stack Deployment

Complete home media automation and streaming solution with Netflix-like interface.

**Stack**: Jellyfin (streaming) + Jellyseerr (requests) + Radarr (movies) + Sonarr (TV) + Prowlarr (indexers) + qBittorrent (downloads)

**Architecture**: API-driven automation with hardlink-based storage efficiency

**Reference**: [TRaSH Guides](https://trash-guides.info/) for Arr stack best practices

---

## Architecture Overview

### Data Flow

```
User Request (Jellyseerr)
         ↓
    Radarr/Sonarr (automation)
         ↓
    Prowlarr (search indexers)
         ↓
    qBittorrent (download)
         ↓
    /data/torrents/ (temp storage)
         ↓
    Radarr/Sonarr (hardlink to library)
         ↓
    /data/media/ (permanent library)
         ↓
    Jellyfin (stream to user)
```

### Storage Strategy

**Critical Design**: All apps must mount `/data` from same PVC for hardlinks to work.

```
/data/                      # Single 1TB Longhorn PVC (RWO)
├── torrents/              # Download directory
│   ├── movies/           # qBittorrent category
│   └── tv/               # qBittorrent category
└── media/                # Media library
    ├── movies/           # Radarr root folder
    └── tv/               # Sonarr root folder
```

**Why hardlinks matter**: Same file appears in both locations, no duplicate storage, allows seeding while streaming.

### Application Summary

**Deployment**: Standard Ansible app structure - see [App Deployment Guide](docs/app-deployment-guide.md)

Each app deploys via: `make app-deploy APP=<name>` (Chart.yml + values.yml + app.yml pattern)

| App         | Purpose            | URL                              | Resources           |
| ----------- | ------------------ | -------------------------------- | ------------------- |
| Jellyfin    | Media streaming    | <https://jellyfin.jardoole.xyz>    | 200m CPU, 512Mi RAM |
| Jellyseerr  | Request management | <https://jellyseerr.jardoole.xyz>  | 100m CPU, 256Mi RAM |
| Radarr      | Movie automation   | <https://radarr.jardoole.xyz>      | 100m CPU, 256Mi RAM |
| Sonarr      | TV automation      | <https://sonarr.jardoole.xyz>      | 100m CPU, 256Mi RAM |
| Prowlarr    | Indexer manager    | <https://prowlarr.jardoole.xyz>    | 50m CPU, 128Mi RAM  |
| qBittorrent | Download client    | <https://qbittorrent.jardoole.xyz> | 200m CPU, 512Mi RAM |

**Total**: ~850m CPU, ~2Gi RAM (fits Beelink N150 with headroom)

**Access**: All apps public with TLS. Future: Keycloak SSO for admin apps. For now: built-in auth only.

---

## ✅ Deployment Status

**All core applications successfully deployed!**

| Component | Status | Notes |
|-----------|--------|-------|
| Storage Infrastructure | ✅ Complete | 1TB media PVC, directory structure initialized |
| qBittorrent | ✅ Deployed | Download client with ProtonVPN integration |
| Prowlarr | ✅ Deployed | Indexer management |
| Radarr | ✅ Deployed | Movie automation |
| Sonarr | ✅ Deployed | TV show automation |
| Jellyfin | ✅ Deployed | Media streaming (config PVC expanded to 10Gi) |
| Jellyseerr | ✅ Deployed | Request management |
| ProtonVPN | ✅ Configured | OpenVPN with automatic port forwarding |

**Recent Fixes:**
- ✅ Jellyfin disk full issue resolved (expanded config PVC 2Gi → 10Gi)
- ✅ ProtonVPN port forwarding working correctly

**Next Steps:** Complete initial configuration using the Getting Started Guide below.

---

## Getting Started Guide 🚀

**Purpose**: Post-deployment manual configuration via web UI

**Prerequisites**: All apps deployed successfully (see Deployment Status above)

This guide walks you through initial configuration after deployment. Total setup time: ~90 minutes.

### Step 1: Access Your Applications

All applications are available via HTTPS with automatic TLS certificates:

| Application | URL | Purpose |
|-------------|-----|---------|
| **qBittorrent** | https://qbittorrent.jardoole.xyz | Torrent download client |
| **Prowlarr** | https://prowlarr.jardoole.xyz | Indexer/tracker manager |
| **Radarr** | https://radarr.jardoole.xyz | Movie automation |
| **Sonarr** | https://sonarr.jardoole.xyz | TV show automation |
| **Jellyfin** | https://jellyfin.jardoole.xyz | Media streaming server |
| **Jellyseerr** | https://jellyseerr.jardoole.xyz | User request interface |

### Step 2: Configure qBittorrent (15 minutes)

**Why first?** All other apps need qBittorrent to download content.

1. **Login**: https://qbittorrent.jardoole.xyz
   - Default credentials: `admin` / `adminadmin`

2. **Change Password**:
   - Tools → Options → Web UI → Authentication
   - Set strong password

3. **Configure Download Paths**:
   - Tools → Options → Downloads:
     - **Default Save Path**: `/data/torrents`
     - **Keep incomplete torrents in**: `/data/torrents/incomplete`

4. **Create Categories**:
   - Right-click in transfer list → Add category
   - **Category 1**:
     - Name: `movies`
     - Save path: `/data/torrents/movies`
   - **Category 2**:
     - Name: `tv`
     - Save path: `/data/torrents/tv`

5. **Configure Seeding Limits**:
   - Tools → Options → BitTorrent → Seeding Limits:
     - **Ratio**: `2.0` (seed to 200%)
     - **Seeding time**: `10080` minutes (7 days)
     - **Then**: Pause torrent

6. **Enable Seeding (Connection Settings)**:
   - Tools → Options → Connection:
     - **Listening Port**: `6881` (matches exposed LoadBalancer port)
     - **Check** ✅ "Use UPnP / NAT-PMP port forwarding from my router"
     - Click **Save**

7. **Configure pfSense UPnP** (if using pfSense router):

   **Install UPnP Package:**
   - pfSense → System → Package Manager → Available Packages
   - Search "miniupnpd" → Install

   **Enable UPnP:**
   - pfSense → Services → UPnP & NAT-PMP
   - **Enable**: ✅ Enable UPnP & NAT-PMP
   - **Allow UPnP Port Mapping**: ✅ Checked
   - **Allow NAT-PMP Port Mapping**: ✅ Checked
   - **External Interface**: WAN
   - **Internal Interface**: LAN

   **Add UPnP ACL** (Access Control List):
   ```
   allow 1024-65535 192.168.0.0/24 1024-65535
   deny 0-65535 0.0.0.0/0 0-65535
   ```
   - Click **Save** and **Apply Changes**

8. **Test Port Connection**:
   - qBittorrent → Tools → Options → Connection
   - Click **"Test Port"** button
   - Should show: "Port is open" ✅
   - Verify in pfSense → Status → UPnP & NAT-PMP
   - Should see port mapping for 192.168.0.166-169:6881

**Alternative (Manual Port Forward):** If you don't want to use UPnP:
- Uncheck UPnP in qBittorrent
- Configure router port forward: External 6881 (TCP+UDP) → 192.168.0.166:6881
- qBittorrent will work but requires manual configuration when ports change

### Step 3: Configure Prowlarr (20 minutes)

**Why second?** Prowlarr provides indexers for Radarr/Sonarr to search.

1. **Complete Initial Setup**: https://prowlarr.jardoole.xyz
   - Follow setup wizard
   - Create authentication (username/password)

2. **Add Indexers**:
   - Settings → Indexers → Add Indexer
   - Add public trackers:
     - **1337x** (general)
     - **The Pirate Bay** (general)
     - **YTS** (movies)
     - **EZTV** (TV shows)
   - Test each indexer before saving

3. **Save API Key** (for later):
   - Settings → General → Security
   - Copy **API Key** (needed for Radarr/Sonarr in next steps)

### Step 4: Configure Radarr (20 minutes)

**Why third?** Radarr needs Prowlarr for searches and qBittorrent for downloads.

1. **Complete Initial Setup**: https://radarr.jardoole.xyz
   - Follow setup wizard
   - Create authentication

2. **Add Root Folder**:
   - Settings → Media Management → Root Folders → Add
   - Path: `/data/media/movies`

3. **Enable Hardlinks** (CRITICAL for storage efficiency):
   - Settings → Media Management → File Management
   - **Enable**: "Use Hardlinks instead of Copy"

4. **Add Download Client**:
   - Settings → Download Clients → Add → qBittorrent
     - **Name**: qBittorrent
     - **Host**: `qbittorrent-app` (internal DNS)
     - **Port**: `8080`
     - **Username**: `admin`
     - **Password**: (your qBittorrent password)
     - **Category**: `movies`
   - Test and Save

5. **Connect Prowlarr**:
   - Settings → Indexers → Add → Prowlarr
     - **Sync Level**: Full Sync
     - **URL**: `http://prowlarr-app:9696`
     - **API Key**: (from Prowlarr Step 3)
   - Test and Save

6. **Save Radarr API Key**:
   - Settings → General → Security
   - Copy **API Key** (needed for Prowlarr and Jellyseerr)

7. **Return to Prowlarr** to complete connection:
   - Prowlarr → Settings → Apps → Add → Radarr
     - **Sync Level**: Full Sync
     - **URL**: `http://radarr-app:7878`
     - **API Key**: (Radarr API key from step 6)
   - Test and Save

### Step 5: Configure Sonarr (20 minutes)

**Same pattern as Radarr but for TV shows.**

1. **Complete Initial Setup**: https://sonarr.jardoole.xyz
   - Create authentication

2. **Add Root Folder**:
   - Settings → Media Management → Root Folders → Add
   - Path: `/data/media/tv`

3. **Enable Hardlinks**:
   - Settings → Media Management → File Management
   - **Enable**: "Use Hardlinks instead of Copy"

4. **Add Download Client**:
   - Settings → Download Clients → Add → qBittorrent
     - **Host**: `qbittorrent-app`
     - **Port**: `8080`
     - **Username/Password**: (qBittorrent credentials)
     - **Category**: `tv`

5. **Connect Prowlarr**:
   - Settings → Indexers → Add → Prowlarr
     - **URL**: `http://prowlarr-app:9696`
     - **API Key**: (from Prowlarr)

6. **Save Sonarr API Key**:
   - Settings → General → Security → API Key

7. **Return to Prowlarr**:
   - Prowlarr → Settings → Apps → Add → Sonarr
     - **URL**: `http://sonarr-app:8989`
     - **API Key**: (Sonarr API key)

### Step 6: Configure Jellyfin (15 minutes)

**Media streaming server - what users actually interact with.**

1. **Initial Setup Wizard**: https://jellyfin.jardoole.xyz
   - Select language
   - Create **admin account** (save credentials!)

2. **Add Media Libraries**:
   - **Movies Library**:
     - Content type: Movies
     - Folder: `/media/media/movies` (Note: Jellyfin mounts PVC at `/media`)
     - Metadata: TMDB (The Movie Database)
   - **TV Shows Library**:
     - Content type: Shows
     - Folder: `/media/media/tv`
     - Metadata: TheTVDB

3. **Configure Remote Access**:
   - Already configured via ingress (https://jellyfin.jardoole.xyz)

4. **Create API Key** (for Jellyseerr):
   - Dashboard → Advanced → API Keys → New
   - **Name**: Jellyseerr
   - Copy and save the API key

5. **Optional - Create User Accounts**:
   - Dashboard → Users → Add User
   - Create accounts for family members

### Step 7: Configure Jellyseerr (10 minutes)

**User-friendly request interface - Netflix-like UI for requesting content.**

1. **Initial Setup**: https://jellyseerr.jardoole.xyz

2. **Connect to Jellyfin**:
   - **URL**: `http://jellyfin-app:8096`
   - **API Key**: (from Jellyfin Step 4)
   - Sign in with your Jellyfin admin account

3. **Connect to Radarr**:
   - Settings → Services → Radarr → Add Server
     - **Server Name**: Radarr
     - **URL**: `http://radarr-app:7878`
     - **API Key**: (from Radarr Step 6)
     - **Quality Profile**: HD-1080p
     - **Root Folder**: `/data/media/movies`
   - Test and Save

4. **Connect to Sonarr**:
   - Settings → Services → Sonarr → Add Server
     - **Server Name**: Sonarr
     - **URL**: `http://sonarr-app:8989`
     - **API Key**: (from Sonarr Step 6)
     - **Quality Profile**: HD-1080p
     - **Root Folder**: `/data/media/tv`
   - Test and Save

5. **Configure User Permissions** (optional):
   - Settings → Users
   - Set request limits per user (e.g., 10 movies/week)

### Step 8: Test End-to-End Workflow (30 minutes)

**Verify the complete automation pipeline works.**

1. **Request Test Content**:
   - Open Jellyseerr: https://jellyseerr.jardoole.xyz
   - Search: "Big Buck Bunny" (open-source test film)
   - Click "Request"
   - Verify status shows "Requested"

2. **Monitor in Radarr**:
   - Open Radarr: https://radarr.jardoole.xyz
   - Activity → Queue: Should show search/download
   - Wait for download to start

3. **Monitor in qBittorrent**:
   - Open qBittorrent: https://qbittorrent.jardoole.xyz
   - Torrent should appear in "movies" category
   - Wait for completion (5-30 minutes)

4. **Verify Import**:
   - Radarr → Activity → History: Should show "Import completed"
   - Radarr → Movies: Movie should have checkmark

5. **Check Jellyfin**:
   - Open Jellyfin: https://jellyfin.jardoole.xyz
   - Library should auto-refresh (or manually: Dashboard → Scan Library)
   - Movie should appear in Movies library
   - Click and test playback

6. **Verify Hardlinks** (CRITICAL):
   ```bash
   kubectl exec -n media deployment/radarr -- ls -li /data/torrents/movies/ /data/media/movies/
   ```
   - Compare inode numbers for the same file
   - **Same inode = SUCCESS** (hardlink, no duplicate storage)
   - **Different inode = PROBLEM** (copy occurred, check Radarr hardlink setting)

7. **Confirm Jellyseerr Status**:
   - Jellyseerr: Request should show "Available"

### Success Checklist ✅

After completing all steps, verify:

- [ ] All apps accessible via HTTPS URLs
- [ ] qBittorrent categories configured (movies, tv)
- [ ] Prowlarr has working indexers
- [ ] Radarr connected to Prowlarr and qBittorrent
- [ ] Sonarr connected to Prowlarr and qBittorrent
- [ ] Jellyfin has Movies and TV libraries
- [ ] Jellyseerr connected to all services
- [ ] Test content requested, downloaded, and plays in Jellyfin
- [ ] Hardlinks verified (same inode numbers)
- [ ] qBittorrent still seeding completed downloads

### Common First-Time Issues

**"qBittorrent login fails"**
- Default credentials: `admin` / `adminadmin`
- Check pod logs: `kubectl logs -n media deployment/qbittorrent`

**"Radarr can't find movies"**
- Check Prowlarr indexers are working (test search)
- Verify Prowlarr → Apps shows Radarr as synced

**"Download stuck at 0%"**
- Check indexer has seeders (Prowlarr → Indexers → Test)
- Verify qBittorrent has internet access
- Check disk space: `kubectl exec -n media deployment/radarr -- df -h /data`

**"Jellyfin library empty after import"** or **"Jellyfin can't read /data/media/movies"**
- **Correct paths for Jellyfin**: `/media/media/movies` and `/media/media/tv`
  - Jellyfin uses official chart that mounts PVC at `/media` (not `/data`)
  - Other apps (Radarr/Sonarr/qBittorrent) mount at `/data`
  - Same PVC, different mount points
- Manually scan: Dashboard → Scan Library
- Check permissions: Files should be readable by UID 1000

**"Storage usage doubled (hardlinks not working)"**
- Check Radarr: Settings → Media Management → "Use Hardlinks" is ON
- Verify all apps mount same PVC (media-stack-data)
- Confirm same filesystem: `df /data/torrents /data/media` (same device)

### Storage Paths Reference

**For configuration reference - all paths are on shared `/data` PVC:**

```
/data/
├── torrents/              # qBittorrent downloads here
│   ├── incomplete/       # Partial downloads
│   ├── movies/          # Completed movie downloads (qBittorrent category)
│   └── tv/              # Completed TV downloads (qBittorrent category)
└── media/               # Final media library (Jellyfin reads from here)
    ├── movies/          # Radarr hardlinks from torrents/movies/
    └── tv/              # Sonarr hardlinks from torrents/tv/
```

**Why this matters**: Hardlinks allow the same file to exist in both locations without using double storage. qBittorrent keeps seeding from `/data/torrents/`, while Jellyfin streams from `/data/media/`.

### What's Next?

**After successful test:**
- Start requesting real content via Jellyseerr
- Configure quality profiles in Radarr/Sonarr (4K, remux, etc.)
- Set up user accounts in Jellyfin for family
- Configure notifications (Discord, Telegram) for new content
- Review storage usage weekly

**Advanced features** (see Phase 11):
- ✅ VPN for qBittorrent privacy (ProtonVPN configured)
- Hardware transcoding for Jellyfin (Intel QuickSync)
- Bazarr for subtitle automation
- Lidarr + Navidrome for music

---

## Remaining Tasks

### Testing & Validation 🧪

**Goal**: Verify complete automation pipeline works end-to-end.

- [ ] **Request test movie via Jellyseerr**

  ```bash
  # Open: https://jellyseerr.jardoole.xyz
  # Search: "Big Buck Bunny" (open-source test film)
  # Click: Request
  # Verify: Request status shows "Requested"
  ```

- [ ] **Monitor Radarr automation at <https://radarr.jardoole.xyz>**
  - Activity → Queue: Should show movie searching/downloading
  - Activity → History: Track events

- [ ] **Monitor qBittorrent download at <https://qbittorrent.jardoole.xyz>**
  - Should see active torrent in "movies" category
  - Wait for completion (5-30 min depending on speed)

- [ ] **Verify Radarr processing**

  ```bash
  # After download completes:
  # Radarr → Activity: Should show "Import" step
  # Radarr → Movies: Movie should appear with checkmark
  ```

- [ ] **Verify Jellyfin library update**

  ```bash
  # Open: https://jellyfin.jardoole.xyz
  # Movies library should auto-refresh (may take 5-10 min)
  # If not: Dashboard → Scan Library
  # Movie should appear in library
  ```

- [ ] **Test playback**

  ```bash
  # Jellyfin: Click movie → Play
  # Verify: Video plays without errors
  # Test: Direct play (no transcoding) works
  ```

- [ ] **Verify hardlinks working** (CRITICAL - ensures no duplicate storage)

  ```bash
  kubectl exec -n media deployment/radarr -- sh -c "ls -li /data/torrents/movies/ /data/media/movies/"
  # Compare inode numbers
  # Same inode = hardlink successful (no duplicate storage)
  # Different inode = copy occurred (PROBLEM - check config)
  ```

- [ ] **Verify Jellyseerr status update**

  ```bash
  # Open: https://jellyseerr.jardoole.xyz
  # Original request should show "Available" status
  ```

**Success Criteria**:

- ✅ Movie appears in Jellyfin within 30 minutes of request
- ✅ Playback works smoothly (no buffering/errors)
- ✅ Hardlinks confirmed (same inode in both locations)
- ✅ Jellyseerr shows "Available" status
- ✅ qBittorrent still seeding (hardlink allows simultaneous seed + stream)

---

### Documentation & Handoff 📖

**Goal**: Document system for future maintenance.

- [ ] **Create media stack overview README**

  ```bash
  # File: apps/media-stack/README.md
  ```

  Include:
  - Architecture diagram
  - Application purposes and URLs
  - Storage layout explanation
  - Common tasks (add content, manage storage)

- [ ] **Document access URLs**

  ```markdown
  ## Access Points (All HTTPS with TLS)

  - Jellyfin: https://jellyfin.jardoole.xyz (streaming)
  - Jellyseerr: https://jellyseerr.jardoole.xyz (requests)
  - Radarr: https://radarr.jardoole.xyz (movie automation)
  - Sonarr: https://sonarr.jardoole.xyz (TV automation)
  - Prowlarr: https://prowlarr.jardoole.xyz (indexers)
  - qBittorrent: https://qbittorrent.jardoole.xyz (downloads)

  **Future**: Keycloak SSO authentication for admin apps
  ```

- [ ] **Create troubleshooting runbook**
      Common issues and solutions (see Troubleshooting Guide below)

- [ ] **Verify all secrets in vault**

  ```bash
  uv run ansible-vault view group_vars/all/vault.yml | grep media -A 20
  ```

  Should contain:
  - vault_qbittorrent_password
  - vault_prowlarr_api_key
  - vault_radarr_api_key
  - vault_sonarr_api_key
  - vault_jellyfin_api_key

- [ ] **Verify Longhorn backups configured**

  ```bash
  # Open: https://longhorn.jardoole.xyz
  # Backup tab: Verify all config PVCs have recent backups
  # Note: media-stack-data is NOT backed up (too large, replaceable)
  ```

---

### Optional Enhancements 🚀

**Goal**: Advanced features for power users.

- [ ] **Deploy Bazarr** (subtitle automation)
  - Only if multilingual subtitles needed
  - Same bjw-s/app-template pattern
  - Connects to Radarr/Sonarr for library sync

- [ ] **Enable hardware transcoding** (Jellyfin)

  Beelink N150 has Intel QuickSync for hardware-accelerated video transcoding. This reduces CPU usage from 80%+ to <10% during streaming.

  **Phase 1: Organize Beelink Playbooks**
  - [ ] Create `playbooks/beelink/` directory (following k3s/minio pattern)
  - [ ] Move existing playbooks: `beelink-setup.yml`, `beelink-storage-config.yml`
  - [ ] Rename with numbered prefixes: `01-initial-setup.yml`, `02-storage-config.yml`
  - [ ] Create `beelink-complete.yml` orchestration playbook
  - [ ] Update Makefile targets to use new paths

  **WHY**: Scalable organization as we add more beelink-specific configuration. Follows established patterns in `playbooks/k3s/` and `playbooks/minio/`.

  **Phase 2: Create Host Prerequisites Playbook**
  - [ ] Create `playbooks/beelink/03-gpu-drivers-setup.yml`
  - [ ] Install Intel media drivers (intel-media-va-driver-non-free)
  - [ ] Install validation tools (intel-gpu-tools, vainfo)
  - [ ] Verify hardware support (check /dev/dri/renderD128 exists)
  - [ ] Detect and register video/render group IDs
  - [ ] Test VA-API functionality with vainfo
  - [ ] Add Makefile target: `make beelink-gpu-setup`

  **WHY**: Ansible ensures idempotent, reproducible setup vs manual SSH commands. Playbook validates prerequisites before touching Kubernetes.

  **Learn more**: [Intel Media Driver](https://github.com/intel/media-driver), [VA-API](https://www.freedesktop.org/wiki/Software/vaapi/)

  **Phase 3: Validate Prerequisites**
  - [ ] Run playbook: `make beelink-gpu-setup`
  - [ ] Review output for detected video/render GIDs
  - [ ] Verify QuickSync profiles available (H.264, HEVC, VP9, AV1 decode)
  - [ ] Document detected GID values for next phase

  **WHY**: Catch hardware/driver issues before Kubernetes changes. Confirms Intel N150 QuickSync is accessible.

  **Learn more**: [Intel QuickSync](https://www.intel.com/content/www/us/en/architecture-and-technology/quick-sync-video/quick-sync-video-general.html)

  **Phase 4: Update Jellyfin Kubernetes Config**
  - [ ] Add /dev/dri hostPath volume mount to `apps/jellyfin/values.yml`
  - [ ] Configure supplementalGroups with detected GIDs (from Phase 3)
  - [ ] Maintain existing security context (no privilege escalation needed)

  **WHY**: Container needs group membership to access /dev/dri devices. SupplementalGroups grants access without privilege escalation.

  **Learn more**: [Kubernetes Security Context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/), [Device Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)

  **Phase 5: Deploy and Verify**
  - [ ] Deploy updated Jellyfin: `make app-deploy APP=jellyfin`
  - [ ] Verify device access: `kubectl exec -n media deployment/jellyfin -- ls -l /dev/dri/`
  - [ ] Test VA-API driver: `kubectl exec -n media deployment/jellyfin -- /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128`

  **WHY**: Validate permissions work before configuring Jellyfin. Confirms container can access GPU.

  **Phase 6: Configure Jellyfin Web UI**
  - [ ] Navigate to Dashboard → Playback → Transcoding
  - [ ] Set Hardware acceleration: **Intel QuickSync (QSV)**
  - [ ] Set VA-API device: **/dev/dri/renderD128**
  - [ ] Enable hardware decoding: H.264, HEVC, VP9, AV1 ✓
  - [ ] Enable hardware encoding: H.264, HEVC ✓ (VP9/AV1 encode not supported on N150)

  **WHY**: Jellyfin must be explicitly configured to use hardware acceleration. Default is software transcoding.

  **Learn more**: [Jellyfin Hardware Acceleration](https://jellyfin.org/docs/general/administration/hardware-acceleration/intel)

  **Phase 7: Test and Validate**
  - [ ] Monitor GPU usage: `ssh beelink` → `intel_gpu_top`
  - [ ] Test transcode by playing HEVC/4K video (forces transcode)
  - [ ] Verify CPU usage: `kubectl top pod -n media` (should be <10% during transcode)
  - [ ] Check logs: `kubectl logs -n media deployment/jellyfin | grep -i "vaapi\|qsv"`

  **WHY**: Confirm hardware transcoding actually working, not silently falling back to software.

  **Learn more**: [Intel GPU Tools](https://gitlab.freedesktop.org/drm/igt-gpu-tools)

  **Phase 8: Documentation**
  - [ ] Update `apps/jellyfin/README.md` with hardware transcoding section
  - [ ] Document playbook execution order
  - [ ] Add troubleshooting guide for common permission issues
  - [ ] Link to Intel/Jellyfin documentation

  **WHY**: Future reference for reinstalls or troubleshooting. Follows `docs/playbook-guidelines.md` standards.

  **Expected Results**:
  - ✅ CPU usage during transcode: 80%+ → <10%
  - ✅ GPU Video/Render engines: 60-90% during transcode
  - ✅ Smooth 4K → 1080p transcoding
  - ✅ Multiple simultaneous 1080p transcodes possible

- [ ] **Add music library** (Lidarr + Navidrome)
  - Lidarr: Music automation (like Radarr for music)
  - Navidrome: Music streaming server (alternative to Jellyfin for music)

- [ ] **Implement request quotas** (Jellyseerr)
  - Settings → Users → Limits
  - Prevent abuse (e.g., 10 movies/week per user)

- [ ] **Configure notifications**
  - Jellyseerr → Discord/Telegram: New request notifications
  - Radarr/Sonarr → Discord: Download completion alerts
  - Jellyfin → Email: New content available

---

## Maintenance Schedule

### Daily (Automated)

- Longhorn config backups (2:00 AM)
- Sonarr checks for new TV episodes
- qBittorrent seeding management (auto-pause at ratio 2.0)

### Weekly (Automated)

- Longhorn full backups (Sunday 3:00 AM)
- Radarr quality upgrade checks

### Monthly (Manual)

- [ ] Review storage usage

  ```bash
  kubectl get pvc -n media
  kubectl exec -n media deployment/radarr -- df -h /data
  ```

- [ ] Check Prowlarr indexer health
- [ ] Update Helm chart versions

  ```bash
  helm repo update
  # Check for new versions, test in phases
  ```

### Quarterly (Manual)

- [ ] Full stack upgrade (new chart versions)
- [ ] Review and prune old media (free up space)
- [ ] Test disaster recovery procedure

---

## Quick Reference Commands

### Access Applications (All Public HTTPS)

```bash
open https://jellyfin.jardoole.xyz      # Streaming
open https://jellyseerr.jardoole.xyz    # Requests
open https://radarr.jardoole.xyz        # Movies
open https://sonarr.jardoole.xyz        # TV
open https://prowlarr.jardoole.xyz      # Indexers
open https://qbittorrent.jardoole.xyz   # Downloads
```

### Check Health

```bash
# Pod status
kubectl get pods -n media

# Resource usage
kubectl top pods -n media

# Storage usage
kubectl exec -n media deployment/radarr -- df -h /data
kubectl get pvc -n media
```

### View Logs

```bash
kubectl logs -n media deployment/radarr --tail=100 -f
kubectl logs -n media deployment/sonarr --tail=100 -f
kubectl logs -n media deployment/qbittorrent --tail=100 -f
kubectl logs -n media deployment/jellyfin --tail=100 -f
```

### Restart Application

```bash
kubectl rollout restart deployment/<app-name> -n media
# Example: kubectl rollout restart deployment/radarr -n media
```

### Expand Storage PVC

```bash
# Edit PVC size
kubectl edit pvc media-stack-data -n media
# Change: storage: 1Ti → storage: 2Ti
# Longhorn will auto-expand (online resize)
```

---

## Troubleshooting Guide

### Radarr can't find movies

**Symptoms**: Manual search returns no results

**Diagnosis**:

- Open <https://prowlarr.jardoole.xyz>
- Test search: System → Tasks → Search Indexers

**Solutions**:

1. Check indexers: Prowlarr → Indexers → Test All
2. Check Radarr integration: Settings → Apps → Radarr (ensure synced)
3. Check quality profile: Radarr → Settings → Profiles (1080p enabled)

---

### qBittorrent downloads stuck

**Symptoms**: Download at 0 B/s, stays at 0%

**Diagnosis**:

```bash
kubectl exec -n media deployment/qbittorrent -- df -h
# Check disk space
kubectl logs -n media deployment/qbittorrent --tail=50
# Check for errors
```

**Solutions**:

1. Check disk space: `df -h /data` (expand PVC if >90% full)
2. Check network: Test Prowlarr search (verifies internet access)
3. Check category paths: qBittorrent → Options → Downloads → Category paths match config
4. Restart qBittorrent: `kubectl rollout restart deployment/qbittorrent -n media`

---

### Jellyfin won't play video

**Symptoms**: "Playback Error" or infinite buffering

**Diagnosis**:

```bash
kubectl exec -n media deployment/jellyfin -- ls -lh /data/media/movies/
# Verify file exists
kubectl logs -n media deployment/jellyfin --tail=100 | grep -i error
```

**Solutions**:

1. Check file permissions: Files should be readable (644 or 755)
2. Try Direct Play: Playback Settings → Disable transcoding
3. Check codec support: H.264 works on all devices, H.265 may require transcoding
4. Check Jellyfin logs for specific error

---

### Hardlinks not working (disk usage doubled)

**Symptoms**: Storage usage = downloads + media (should be same)

**Diagnosis**:

```bash
kubectl exec -n media deployment/radarr -- ls -li /data/torrents/movies/
kubectl exec -n media deployment/radarr -- ls -li /data/media/movies/
# Compare inode numbers - should be identical
```

**Solutions**:

1. Verify all apps mount same PVC:

   ```bash
   kubectl get pods -n media -o yaml | grep -A 5 persistentVolumeClaim
   # All should reference "media-stack-data"
   ```

2. Check Radarr hardlink setting:
   - Settings → Media Management → File Management
   - "Use Hardlinks instead of Copy" = ON
3. Verify directories on same filesystem:

   ```bash
   kubectl exec -n media deployment/radarr -- df /data/torrents /data/media
   # Same filesystem = same device
   ```

4. If copy occurred, delete duplicate and re-import:

   ```bash
   # In Radarr: Movie → Delete Files → Unmonitor
   # Move file manually or trigger new download
   ```

---

### Jellyseerr can't connect to Radarr/Sonarr

**Symptoms**: "Connection failed" when testing Radarr/Sonarr in Jellyseerr

**Diagnosis**:

```bash
kubectl get svc -n media
# Verify services exist: radarr, sonarr
kubectl exec -n media deployment/jellyseerr -- nslookup radarr.media.svc.cluster.local
# Verify DNS resolution
```

**Solutions**:

1. Check service names: Should be `<app>.media.svc.cluster.local`
2. Verify API keys match: Compare Radarr UI → Settings → General → API Key vs Jellyseerr config
3. Check ports: Radarr=7878, Sonarr=8989
4. Restart Jellyseerr: `kubectl rollout restart deployment/jellyseerr -n media`

---

### Storage PVC full

**Symptoms**: Downloads fail, "No space left on device"

**Diagnosis**:

```bash
kubectl exec -n media deployment/radarr -- df -h /data
# Check usage percentage
```

**Solutions**:

1. **Immediate**: Delete old torrents

   ```bash
   # qBittorrent → Select old torrents → Delete (with files)
   ```

2. **Short-term**: Expand PVC

   ```bash
   kubectl edit pvc media-stack-data -n media
   # Change: storage: 1Ti → storage: 2Ti
   # Save and Longhorn will auto-expand
   ```

3. **Long-term**: Configure aggressive seeding limits
   - qBittorrent → Options → BitTorrent → Seeding Limits
   - Lower ratio to 1.0 or time to 3 days
4. **Archive**: Delete watched content
   - Jellyfin: Mark as watched
   - Radarr/Sonarr: Unmonitor and delete files

---

## Architecture Summary

### Complete Stack Overview

```
┌─────────────────────────────────────────────────────────┐
│                  USER INTERACTION LAYER                 │
├─────────────────────────────────────────────────────────┤
│  Jellyfin (Stream)          Jellyseerr (Request)        │
│  jellyfin.jardoole.xyz      jellyseerr.jardoole.xyz     │
│  Public HTTPS               Public HTTPS                │
└────────────┬─────────────────────────┬──────────────────┘
             │                         │
             │ (API)                   │ (API)
             │                         ▼
             │                ┌─────────────────────┐
             │                │  AUTOMATION LAYER   │
             │                ├─────────────────────┤
             │                │ Radarr     Sonarr   │
             │                │ (Movies)   (TV)     │
             │                └──────┬──────────────┘
             │                       │ (API)
             │                       ▼
             │                ┌─────────────────────┐
             │                │   Prowlarr          │
             │                │   (Indexers)        │
             │                └──────┬──────────────┘
             │                       │ (Search)
             │                       ▼
             │                ┌─────────────────────┐
             │                │  qBittorrent        │
             │                │  (Downloads)        │
             │                └──────┬──────────────┘
             │                       │
             │                       ▼
             │              /data/torrents/movies/
             │              /data/torrents/tv/
             │                       │
             │                (Hardlink - no copy)
             │                       │
             │                       ▼
             │              /data/media/movies/
             │              /data/media/tv/
             │                       │
             └───────────────────────┘
                    (Jellyfin reads library)
```

### Storage Layout

```
Beelink Node (6TB NVMe):
└── Longhorn Volumes
    ├── media-stack-data (1TB RWO) ← ALL APPS MOUNT THIS
    │   ├── /data/torrents/movies/
    │   ├── /data/torrents/tv/
    │   ├── /data/media/movies/
    │   └── /data/media/tv/
    ├── radarr-config (1Gi) ← Backed up
    ├── sonarr-config (1Gi) ← Backed up
    ├── prowlarr-config (500Mi) ← Backed up
    ├── qbittorrent-config (500Mi) ← Backed up
    ├── jellyfin-config (2Gi) ← Backed up
    ├── jellyfin-cache (5Gi) ← NOT backed up (transcoding cache)
    └── jellyseerr-config (500Mi) ← Backed up
```

**Backup Strategy**:

- Config volumes: Backed up via Longhorn (daily/weekly)
- Media volume: NOT backed up (too large 1TB+, replaceable)
- Recovery: Restore configs, re-import or re-download media

### Network Architecture

```
Internet (Port 443)
    ↓
Traefik Ingress Controller (with TLS via cert-manager)
    ├── jellyfin.jardoole.xyz → Jellyfin:8096
    ├── jellyseerr.jardoole.xyz → Jellyseerr:5055
    ├── radarr.jardoole.xyz → Radarr:7878
    ├── sonarr.jardoole.xyz → Sonarr:8989
    ├── prowlarr.jardoole.xyz → Prowlarr:9696
    └── qbittorrent.jardoole.xyz → qBittorrent:8080

Cluster Internal (Service Discovery for app-to-app):
    ├── radarr.media.svc.cluster.local:7878
    ├── sonarr.media.svc.cluster.local:8989
    ├── prowlarr.media.svc.cluster.local:9696
    ├── qbittorrent.media.svc.cluster.local:8080
    ├── jellyfin.media.svc.cluster.local:8096
    └── jellyseerr.media.svc.cluster.local:5055

Pod-to-Internet (Egress):
    ├── Prowlarr → Indexer websites (search)
    ├── qBittorrent → Torrent swarm (download)
    ├── Radarr/Sonarr → TheTVDB/TMDB (metadata)
    └── Jellyseerr → TMDB (movie/show info)

**Future**: Keycloak SSO for admin apps (Radarr/Sonarr/Prowlarr/qBittorrent)
```

---

## Success Metrics

### Phase 9 Complete Checklist

- [ ] ✅ All 6 apps running: `kubectl get pods -n media` (6/6 ready)
- [ ] ✅ End-to-end test passed (request → download → playback)
- [ ] ✅ Hardlinks verified (inode check)
- [ ] ✅ Jellyfin accessible: <https://jellyfin.jardoole.xyz>
- [ ] ✅ Jellyseerr accessible: <https://jellyseerr.jardoole.xyz>
- [ ] ✅ All API integrations working (Prowlarr ↔ Radarr/Sonarr ↔ qBittorrent)
- [ ] ✅ Backups configured: Longhorn daily/weekly for configs
- [ ] ✅ Documentation complete: README + runbooks

### Performance Targets

- **Request-to-Available**: < 30 minutes (typical movie)
- **Playback Start**: < 5 seconds (direct play, no transcoding)
- **Storage Efficiency**: ~50% savings via hardlinks (1 copy vs 2)
- **Uptime**: 99%+ (no single point of failure with Longhorn replication)

### Recovery Objectives

- **RTO** (Recovery Time Objective): 30-45 minutes for full cluster rebuild
- **RPO** (Recovery Point Objective): 24 hours (last nightly config backup)
- **Media Library Recovery**: Re-import or re-download (days to weeks)

---

## Key Takeaways

✅ **Deployment**: Standard Ansible app structure (`make app-deploy APP=<name>`)
✅ **Architecture**: 6-app stack, API-driven automation, hardlinks for efficiency
✅ **Storage**: Single RWO PVC (1TB) on Beelink, all pods node-affinitized
✅ **Integration**: Jellyseerr (front-end) → Arr apps (automation) → qBittorrent (downloads) → Jellyfin (streaming)
✅ **Backup**: Longhorn daily/weekly for configs, media NOT backed up (replaceable)
✅ **Access**: All apps public HTTPS with TLS. Future: Keycloak SSO for admin apps
✅ **Hardlinks**: Critical for efficiency - all apps MUST mount same `/data` PVC

**Next Action**: Phase 1 - Create namespace and add Helm repositories

**Estimated Timeline**: 4-6 hours for complete deployment (mostly manual UI configuration)

**Reference**: [TRaSH Guides](https://trash-guides.info/) for advanced Arr stack configuration
