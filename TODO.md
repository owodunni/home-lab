# TODO - Remaining Tasks

## Overview

**✅ Completed**: Full media stack deployed and configured
- 6 apps running (Jellyfin, Jellyseerr, Radarr, Sonarr, Prowlarr, qBittorrent)
- All UI configuration complete
- Intel QuickSync hardware transcoding enabled
- API integrations working
- End-to-end workflow tested (request → download → playback)

**⚠️ Remaining**: Critical testing before production use

---

## Critical Testing 🧪

### 1. Verify Hardlinks Working

**Why**: Hardlinks prevent duplicate storage. Without them, media exists in both `/data/torrents/` AND `/data/media/`, using 2x storage.

**Status**: ⚠️ **NOT YET VERIFIED**

**How to test** (< 5 minutes):

```bash
# Check inode numbers in both locations
kubectl exec -n media deployment/radarr -- ls -li /data/torrents/movies/ | head -3
kubectl exec -n media deployment/radarr -- ls -li /data/media/movies/ | head -3

# Expected: SAME inode numbers = hardlink working (one file, appears in two places)
# Problem: DIFFERENT inode numbers = copy occurred (two separate files, 2x storage)
```

**Example output** (good):
```
12345678 -rw-r--r-- 2 abc abc 1.5G Movie.mkv  (in torrents/)
12345678 -rw-r--r-- 2 abc abc 1.5G Movie.mkv  (in media/)
^^^^^^^^ Same inode = SUCCESS
```

**If failed** (different inodes):
1. Check: Radarr → Settings → Media Management → "Use Hardlinks instead of Copy" = ON
2. Verify all apps mount same PVC: `kubectl get pods -n media -o yaml | grep persistentVolumeClaim`
3. Re-import: Delete duplicate, trigger Radarr re-import (will use hardlink)

---

### 2. Test Backup Restore

**Why**: Backups are worthless if you can't restore. Test before you need it.

**Status**: ⚠️ **NOT YET TESTED**

#### Test 1: Individual PVC Restore (~15 minutes)

```bash
# Choose test PVC (prowlarr-config - smallest, least critical)

# Step 1: Take manual backup
# Longhorn UI → Volumes → prowlarr-config → Create Backup

# Step 2: Delete PVC
kubectl delete pvc prowlarr-config -n media

# Step 3: Restore from backup
# Longhorn UI → Backup → Select backup → Restore (name: prowlarr-config)

# Step 4: Redeploy app
make app-deploy APP=prowlarr

# Step 5: Verify all settings intact
# Open: https://prowlarr.jardoole.xyz
# Check: Indexers, API keys, app connections all present
```

**Expected**: Full restore in < 10 minutes, zero config loss

#### Test 2: Document Cluster State (before disaster recovery)

```bash
# Create snapshot of current state
kubectl get pvc --all-namespaces > cluster-backup-$(date +%Y%m%d).txt
kubectl get deployments --all-namespaces >> cluster-backup-$(date +%Y%m%d).txt
helm list --all-namespaces >> cluster-backup-$(date +%Y%m%d).txt

# Note Longhorn S3 settings
# Longhorn UI → Setting → Backup Target (record S3 URL and bucket)
```

#### Test 3: Full Disaster Recovery (OPTIONAL - high risk)

**WARNING**: Only test during planned maintenance or on non-production cluster.

```bash
# Scenario: Complete hardware failure, rebuild from scratch

# 1. Fresh cluster
make k3s-cluster      # Rebuild K3s
make cert-manager     # TLS
make longhorn         # Storage

# 2. Configure same S3 backend in Longhorn
# Longhorn UI → Setting → Backup Target → Enter S3 URL

# 3. Restore all config PVCs
# Longhorn UI → Backup → Restore each (jellyfin-config, radarr-config, etc.)

# 4. Redeploy applications
make app-deploy APP=jellyfin
make app-deploy APP=radarr
# ... etc

# 5. Verify full recovery
# All apps accessible, API integrations working, media library intact
```

**Expected**: Full rebuild + restore < 2 hours

**Document**: Create `docs/disaster-recovery.md` with tested procedures

---

## Optional Enhancements 🚀

### Future Features (when ready)

- [ ] **Deploy Bazarr** (subtitle automation)
  - Only if multilingual subtitles needed
  - Same bjw-s/app-template pattern
  - Connects to Radarr/Sonarr

- [ ] **Add Music Library** (Lidarr + Navidrome)
  - Lidarr: Music automation (like Radarr for music)
  - Navidrome: Music streaming server

- [ ] **Configure Notifications**
  - Jellyseerr → Discord/Telegram: New requests
  - Radarr/Sonarr → Discord: Download completion
  - Jellyfin → Email: New content available

- [ ] **Implement Request Quotas**
  - Jellyseerr → Settings → Users → Limits
  - Prevent abuse (e.g., 10 movies/week per user)

---

## Quick Reference

### Access URLs (All HTTPS)

- **Jellyfin**: https://jellyfin.jardoole.xyz (streaming)
- **Jellyseerr**: https://jellyseerr.jardoole.xyz (requests)
- **Radarr**: https://radarr.jardoole.xyz (movies)
- **Sonarr**: https://sonarr.jardoole.xyz (TV)
- **Prowlarr**: https://prowlarr.jardoole.xyz (indexers)
- **qBittorrent**: https://qbittorrent.jardoole.xyz (downloads)
- **Longhorn**: https://longhorn.jardoole.xyz (storage/backups)

### Useful Commands

```bash
# Pod status
kubectl get pods -n media

# Resource usage
kubectl top pods -n media

# Storage usage
kubectl exec -n media deployment/radarr -- df -h /data

# App logs
kubectl logs -n media deployment/{app} --tail=100 -f

# Restart app
kubectl rollout restart deployment/{app} -n media

# Storage expansion
kubectl edit pvc media-stack-data -n media
# Change: storage: 1Ti → storage: 2Ti
```

### Documentation

- **Complete Guide**: `docs/media-stack-complete-guide.md` (full setup, architecture, troubleshooting)
- **App Deployment**: `docs/app-deployment-guide.md` (Helm chart deployment pattern)
- **Hardware Transcoding**: `apps/jellyfin/README.md` (Intel QuickSync setup)
- **Git Commits**: `docs/git-commit-guidelines.md` (commit message standards)
- **Project Structure**: `docs/project-structure.md` (architecture overview)

---

## Next Steps

1. ✅ **Mark this complete** when hardlinks verified and backup restore tested
2. ✅ **Create** `docs/disaster-recovery.md` based on tested procedures
3. ✅ **Enjoy** your fully automated media stack!

**For detailed setup/troubleshooting**: See `docs/media-stack-complete-guide.md`
