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
/data/                      # hostPath storage on Beelink (/mnt/storage/media)
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

| Application     | URL                                | Purpose                 |
| --------------- | ---------------------------------- | ----------------------- |
| **qBittorrent** | <https://qbittorrent.jardoole.xyz> | Torrent download client |
| **Prowlarr**    | <https://prowlarr.jardoole.xyz>    | Indexer/tracker manager |
| **Radarr**      | <https://radarr.jardoole.xyz>      | Movie automation        |
| **Sonarr**      | <https://sonarr.jardoole.xyz>      | TV show automation      |
| **Jellyfin**    | <https://jellyfin.jardoole.xyz>    | Media streaming server  |
| **Jellyseerr**  | <https://jellyseerr.jardoole.xyz>  | User request interface  |

### Step 2: Configure qBittorrent (15 minutes) ✅ **COMPLETE**

**Why first?** All other apps need qBittorrent to download content.

1. **Login**: <https://qbittorrent.jardoole.xyz>
   - Default credentials are randomized: `kubectl logs -n media -l app.kubernetes.io/name=qbittorrent --tail=50`

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
     - **Listening Port**: `6881` (matches exposed gluetun port, check logs)
     - **Check** ✅ "Use UPnP / NAT-PMP port forwarding from my router"
     - Click **Save**

### Step 3: Configure Prowlarr (20 minutes) ✅ **COMPLETE**

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

### Step 4: Configure Radarr (20 minutes) ✅ **COMPLETE**

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

### Step 5: Configure Sonarr (20 minutes) ✅ **COMPLETE**

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

### Step 6: Configure Jellyfin (15 minutes) ✅ **COMPLETE**

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

### Step 7: Configure Jellyseerr (10 minutes) ✅ **COMPLETE**

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

- [x] All apps accessible via HTTPS URLs
- [x] qBittorrent categories configured (movies, tv)
- [x] Prowlarr has working indexers
- [x] Radarr connected to Prowlarr and qBittorrent
- [x] Sonarr connected to Prowlarr and qBittorrent
- [x] Jellyfin has Movies and TV libraries
- [x] Jellyseerr connected to all services
- [x] Test content requested, downloaded, and plays in Jellyfin
- [ ] Hardlinks verified (same inode numbers) ⚠️ **PENDING - See Step 8**
- [x] qBittorrent still seeding completed downloads

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

  **What are hardlinks?**
  - Same file appears in two locations (/data/torrents/ and /data/media/)
  - Only uses storage space ONCE (not duplicated)
  - Allows qBittorrent to seed while Jellyfin streams

  **Why test this?**
  - If hardlinks fail, you're using 2x storage (complete duplicate of media library)
  - 1TB of media would require 2TB of storage (downloads + library)

  **How to verify:**
  ```bash
  # List files in both locations with inode numbers
  kubectl exec -n media deployment/radarr -- ls -li /data/torrents/movies/ | head -5
  kubectl exec -n media deployment/radarr -- ls -li /data/media/movies/ | head -5

  # Example output showing HARDLINK (good):
  # 12345678 -rw-r--r-- 2 abc abc 1.5G Nov 14 Big.Buck.Bunny.mkv  (in torrents/)
  # 12345678 -rw-r--r-- 2 abc abc 1.5G Nov 14 Big.Buck.Bunny.mkv  (in media/)
  #   ^^^^^^^^ Same inode = SUCCESS (hardlink, one file, uses 1.5G total)
  #
  # Link count = 2 (shown after permissions) also confirms hardlink
  #
  # Example output showing COPY (bad):
  # 12345678 -rw-r--r-- 1 abc abc 1.5G Nov 14 Big.Buck.Bunny.mkv  (in torrents/)
  # 87654321 -rw-r--r-- 1 abc abc 1.5G Nov 14 Big.Buck.Bunny.mkv  (in media/)
  #   ^^^^^^^^ Different inodes = FAILURE (two separate files, uses 3.0G total)
  ```

  **If hardlinks failed (different inodes):**

  1. **Check Radarr setting:**
     ```
     Radarr → Settings → Media Management → File Management
     "Use Hardlinks instead of Copy" must be ON ✓
     ```

  2. **Verify same PVC mount:**
     ```bash
     kubectl get pods -n media -o yaml | grep -A 5 persistentVolumeClaim
     # All should reference "media-stack-data" PVC
     ```

  3. **Check filesystem:**
     ```bash
     kubectl exec -n media deployment/radarr -- df /data/torrents /data/media
     # Must show SAME filesystem device for hardlinks to work
     ```

  4. **Fix by re-importing:**
     ```bash
     # Delete the duplicate file from /data/media/ (keep torrent copy)
     # In Radarr: Movie → Delete Files → Yes
     # Then: Movie → Search → Select torrent → Manual import
     # Radarr will re-import using hardlink (with correct setting)
     ```

  **Expected result:** Same inode numbers = storage efficient hardlinks working correctly

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

- [ ] **Verify restic backups configured**

  ```bash
  # Open: https://beelink (SSH)
  # Backup tab: Verify all config PVCs have recent backups
  # Note: media-stack-data is NOT backed up (too large, replaceable)
  ```

### Backup & Disaster Recovery Testing 🔄

**CRITICAL**: Backups are worthless if you can't restore from them. Test recovery procedures before you need them.

- [ ] **Test Individual PVC Restore**

  **Goal**: Verify you can restore a single PVC from restic backup.

  ```bash
  # Choose a test PVC (e.g., prowlarr-config - smallest, least critical)
  # Step 1: Note current state
  kubectl exec -n media deployment/prowlarr -- ls -la /config/

  # Step 2: Take manual backup
  # NFS storage → Volume → prowlarr-config → Create Backup
  # Note backup name (e.g., backup-abc123...)

  # Step 3: Simulate data loss
  kubectl delete pvc prowlarr-config -n media
  # Wait for volume to delete

  # Step 4: Restore from backup
  # restic backup → Restore
  # Name: prowlarr-config
  # Wait for PVC creation

  # Step 5: Redeploy app
  make app-deploy APP=prowlarr

  # Step 6: Verify data intact
  # Open: https://prowlarr.jardoole.xyz
  # Verify: All indexers, settings, API keys present
  ```

  **Expected Result**: Full restore in < 10 minutes, zero config loss

- [ ] **Document Current Cluster State** (before disaster recovery test)

  ```bash
  # List all PVCs
  kubectl get pvc --all-namespaces -o wide > cluster-pvcs-backup.txt

  # List all deployments
  kubectl get deployments --all-namespaces > cluster-deployments-backup.txt

  # Backup all Helm releases
  helm list --all-namespaces > cluster-helm-releases.txt

  # Document restic backup settings
  # ssh beelink "restic snapshots" to verify backup state
  ```

- [ ] **Test Full Cluster Disaster Recovery** (OPTIONAL - high risk)

  **WARNING**: Only do this on a non-production cluster or during planned maintenance.

  ```bash
  # Scenario: Complete hardware failure, fresh cluster rebuild from backups

  # Step 1: Fresh K3s installation
  make k3s-cluster    # Rebuilds K3s from scratch

  # Step 2: Restore infrastructure
  make cert-manager   # TLS certificate management
  make nfs-storage    # NFS provisioner

  # Step 3: Restore app configs from restic
  ssh beelink "restic restore latest --target /mnt/storage/k8s-apps"

  # Step 4: Restore media from restic (if needed)
  ssh beelink "restic restore latest --target /mnt/storage/media"

  # Step 5: Redeploy all applications
  make app-deploy APP=jellyfin
  make app-deploy APP=radarr
  make app-deploy APP=sonarr
  # ... etc for all apps

  # Step 6: Verify complete recovery
  # All apps accessible via HTTPS
  # All API integrations working
  # Jellyfin shows all media (metadata intact)
  # Radarr/Sonarr settings preserved
  ```

  **Expected Results**:
  - Individual PVC restore: < 10 minutes
  - Full cluster rebuild + restore: < 2 hours
  - Zero configuration loss (all settings from S3 backups)
  - Media library intact (file structure + metadata)

  **Document Recovery Times**:
  - Record actual time for each step
  - Note any issues encountered
  - Update disaster recovery documentation

- [ ] **Create Disaster Recovery Documentation**

  ```bash
  # Create: docs/disaster-recovery.md
  ```

  Include:
  - Step-by-step cluster rebuild procedure
  - S3 bucket structure and backup naming
  - Recovery time objectives (RTO: < 2 hours)
  - Recovery point objectives (RPO: 24 hours daily backups)
  - Troubleshooting common restore issues
  - Contact info for MinIO access
  - List of applications in deployment order

---

### Optional Enhancements 🚀

**Goal**: Advanced features for power users.

- [ ] **Deploy Bazarr** (subtitle automation)
  - Only if multilingual subtitles needed
  - Same bjw-s/app-template pattern
  - Connects to Radarr/Sonarr for library sync

- [x] **Enable hardware transcoding** (Jellyfin) - ✅ **COMPLETE**

  Intel QuickSync (QSV) hardware video transcoding with oneVPL library support successfully implemented.

  **Results:**
  - CPU usage: 170% → ~30-40% during 4K HDR transcoding
  - GPU Video engine: 70-90% utilization (real-time encoding, no playback lag)
  - Encoding speed: 2.4x realtime for 1080p H.264

  **Implementation:**
  - LinuxServer.io Jellyfin image (Ubuntu GLIBC 2.39) for driver compatibility
  - bjw-s/app-template chart for flexible hostPath mounting
  - Host oneVPL libraries (libvpl2, libmfx-gen1.2) mounted to fix QSV encoder
  - NFD + Intel GPU plugin auto-deployed as prerequisites

  **Full documentation:** `apps/jellyfin/README.md`

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

- restic backups (2:00 AM)
- Sonarr checks for new TV episodes
- qBittorrent seeding management (auto-pause at ratio 2.0)

### Weekly (Automated)

- restic backups (Sunday 3:00 AM)
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
# Storage is on Beelink MergerFS pool
# To add more storage, add drives to MergerFS:
ssh beelink "df -h /mnt/storage"
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
   # Check available storage on Beelink
   ssh beelink "df -h /mnt/storage"
   # To add capacity, add drives to MergerFS pool
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
Beelink Node (6TB NVMe via MergerFS):
└── /mnt/storage (MergerFS pool)
    ├── media/                    ← ALL APPS MOUNT THIS
    │   ├── torrents/movies/
    │   ├── torrents/tv/
    │   ├── library/movies/
    │   └── library/tv/
    └── k8s-apps/                 ← App configs (backed up)
        ├── radarr-config/
        ├── sonarr-config/
        ├── prowlarr-config/
        ├── qbittorrent-config/
        ├── jellyfin-config/
        └── jellyseerr-config/
```

**Backup Strategy**:

- App configs: Backed up via restic to MinIO S3 (daily 3 AM)
- Media files: Backed up via restic to MinIO S3 (daily 3 AM)
- Recovery: Restore from restic snapshots, redeploy apps

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

- [x] ✅ All 6 apps running: `kubectl get pods -n media` (6/6 ready)
- [x] ✅ End-to-end test passed (request → download → playback)
- [ ] ⚠️ Hardlinks NOT YET verified (inode check pending)
- [x] ✅ Jellyfin accessible: <https://jellyfin.jardoole.xyz>
- [x] ✅ Jellyseerr accessible: <https://jellyseerr.jardoole.xyz>
- [x] ✅ All API integrations working (Prowlarr ↔ Radarr/Sonarr ↔ qBittorrent)
- [x] ✅ Backups configured: restic daily to MinIO S3
- [ ] ⚠️ Backup restore testing pending (see Backup & Disaster Recovery Testing section)
- [x] ✅ Documentation complete: README + runbooks
- [x] ✅ Hardware transcoding enabled (Intel QuickSync QSV with oneVPL)

### Performance Targets

- **Request-to-Available**: < 30 minutes (typical movie)
- **Playback Start**: < 5 seconds (direct play, no transcoding)
- **Storage Efficiency**: ~50% savings via hardlinks (1 copy vs 2)
- **Uptime**: 99%+ (NFS storage with SnapRAID parity protection)

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
✅ **Backup**: restic daily for configs and media to MinIO S3
✅ **Access**: All apps public HTTPS with TLS. Future: Keycloak SSO for admin apps
✅ **Hardlinks**: Critical for efficiency - all apps MUST mount same `/data` PVC

**Next Action**: Phase 1 - Create namespace and add Helm repositories

**Estimated Timeline**: 4-6 hours for complete deployment (mostly manual UI configuration)

**Reference**: [TRaSH Guides](https://trash-guides.info/) for advanced Arr stack configuration
