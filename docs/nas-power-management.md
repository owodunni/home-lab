# MinIO NAS Power Management

Configuration for automatic disk spin-down on MinIO NAS storage to reduce power consumption and extend HDD lifespan.

## Overview

The MinIO NAS (pi-cm5-4) uses 2x 2TB SATA HDDs for S3 backup storage. These drives are accessed infrequently (primarily for Longhorn and restic backups), making them ideal candidates for automatic spin-down to reduce power consumption and extend drive lifespan during idle periods.

**Power Savings:** ~11W during idle periods (both drives spun down)

## Configuration

- **Spin-down timeout:** 5 minutes after last access
- **APM level:** 128 (balanced - enables spin-down while preserving performance)
- **MinIO scanner:** Slowest speed, 6-hour cycle delay
- **Persistence:** udev rules automatically apply settings on boot and device hotplug
- **Technology:** hdparm (industry-standard disk power management tool)

### Target Devices

- `/dev/disk/by-id/wwn-0x5000c5008a1a78df` (minio-disk1 - data drive)
- `/dev/disk/by-id/wwn-0x5000c5008a1a7d0f` (minio-parity1 - parity drive)

## Deployment

Deploy disk spin-down configuration:

```bash
make nas-spindown
```

This will:
1. Install hdparm package
2. Create udev rule `/etc/udev/rules.d/69-hdparm-spindown.rules`
3. Apply settings immediately (no reboot required)
4. Display verification commands

## Verification Commands

### Check Current Power State

```bash
# SSH to NAS node
ssh pi-cm5-4

# Check drive power state
sudo hdparm -C /dev/disk/by-id/wwn-0x5000c5008a1a78df

# Output: drive state is:  active/idle or standby
```

### Check Current Settings

View the configured spin-down timeout and APM level:

```bash
sudo hdparm -I /dev/disk/by-id/wwn-0x5000c5008a1a78df | grep -i "power\|standby"
```

Look for:
- `Advanced power management level: 128`
- `standby` in the power management section

### Force Immediate Spin-Down (Testing)

Manually spin down a drive to test configuration:

```bash
sudo hdparm -y /dev/disk/by-id/wwn-0x5000c5008a1a78df

# Wait 2 seconds
sleep 2

# Verify drive is in standby
sudo hdparm -C /dev/disk/by-id/wwn-0x5000c5008a1a78df
# Should show: drive state is:  standby
```

### Monitor Spin-Up Events

Watch syslog for drive spin-up messages:

```bash
tail -f /var/log/syslog | grep -i "ata\|scsi"
```

### Monitor Automatic Spin-Down

Continuously monitor drive state every 5 minutes for 35 minutes to observe automatic spin-down:

```bash
watch -n 300 'sudo hdparm -C /dev/disk/by-id/wwn-0x5000c5008a1a78df'
```

After 30 minutes of inactivity, the drive state should change from `active/idle` to `standby`.

## How It Works

1. **hdparm -S 60**: Sets spin-down timeout to 5 minutes
   - Values 1-240: timeout in 5-second units (e.g., 60 = 5 min, 240 = 20 min)
   - Values 241-251: timeout in 30-minute units (241 = 30 min, 242 = 60 min, etc.)
2. **hdparm -B 128**: Sets APM (Advanced Power Management) level to 128 (balanced mode)
   - Values 128-254: Performance mode with APM enabled
   - 128 = Balanced (enables spin-down while preserving performance)
   - 254 = Maximum performance (minimal power saving)
3. **udev rules**: Kernel automatically reapplies settings when drives are detected (boot, hotplug)
4. **On-demand spin-up**: Drives transparently spin up when accessed (~5-10 second delay)

### udev Rule

The configuration uses a udev rule that matches drives by WWN (World Wide Name):

```
# /etc/udev/rules.d/69-hdparm-spindown.rules
ACTION=="add|change", ENV{ID_WWN}=="0x5000c5008a1a78df", RUN+="/usr/sbin/hdparm -S 60 -B 128 /dev/%k"
ACTION=="add|change", ENV{ID_WWN}=="0x5000c5008a1a7d0f", RUN+="/usr/sbin/hdparm -S 60 -B 128 /dev/%k"
```

WWN identifiers are stable across reboots and not affected by `/dev/sdX` device name changes.

### MinIO Background Activity Configuration

MinIO runs background processes (scanner, healing, and drive health monitoring) that can prevent drives from spinning down. The configuration minimizes this activity:

```bash
# /etc/minio/minio.conf (via group_vars/nas/main.yml)
MINIO_SCANNER_SPEED="slowest"          # Minimize disk I/O during scans
MINIO_SCANNER_CYCLE="6h"               # Only scan every 6 hours
MINIO_HEAL_BITROTSCAN="off"            # Disable bitrot scanning (background reads)
MINIO_HEAL_MAX_SLEEP="5s"              # Slow down healing operations
_MINIO_DRIVE_ACTIVE_MONITORING="off"   # Disable drive health checks (prevents tmp writes)
```

**Warning**: Disabling drive health monitoring means MinIO won't proactively detect hung drives or I/O issues. Since this is a backup-only system with infrequent access, the risk is acceptable.

This allows drives to remain spun down for up to 6 hours between scanner cycles, significantly improving power savings.

## Expected Behavior

### Normal Operation

1. MinIO backup runs → drives spin up automatically
2. Backup completes → drives become idle
3. After 5 minutes idle → drives spin down to standby
4. Next backup → drives spin up automatically (transparent to MinIO)
5. MinIO scanner runs every 6 hours (drives spin up briefly)

### Daily SnapRAID Sync (5 AM)

1. Sync starts → drives spin up if in standby
2. Sync completes → drives become idle
3. After 30 minutes → drives spin down

### Backup Schedules

The NAS drives are accessed during:
- **Longhorn backups**: As configured in Longhorn System settings
- **Restic backups from Beelink**: Daily at 3 AM
- **SnapRAID sync**: Daily at 5 AM (MinIO NAS)

Between these scheduled operations, drives will automatically spin down after 30 minutes of inactivity.

## Power Consumption

### Estimated Power Draw

- **Active (spinning)**: ~6W per drive
- **Standby (spun down)**: ~0.5W per drive
- **Savings per drive**: ~5.5W during idle periods
- **Total savings (both drives)**: ~11W during idle periods

### Annual Savings

Assuming drives are idle ~18 hours per day (75% of the time):
- **Power saved**: 11W × 18 hours = 198 Wh per day
- **Annual savings**: 198 Wh × 365 days = 72.27 kWh/year

At typical electricity rates (~$0.12/kWh), this saves approximately **$8.67 per year** in electricity costs while reducing wear on the drives.

## Customization

To adjust timeout or APM level, edit `/home/alexanderp/Prog/home-lab/group_vars/nas/main.yml`:

```yaml
# Spin-down timeout: hdparm -S parameter (0-255)
# 1-240: timeout in 5-second units (e.g., 60 = 5 min, 120 = 10 min, 240 = 20 min)
# 241-251: timeout in 30-minute units (241 = 30 min, 242 = 60 min, etc.)
minio_disk_spindown_timeout: 60

# APM level (1-255)
# 1 = maximum power saving (aggressive spin-down)
# 128 = balanced (recommended)
# 254 = maximum performance (minimal power saving)
# 255 = disable APM
minio_disk_apm_level: 128
```

After editing, redeploy the configuration:

```bash
make nas-spindown
```

## Troubleshooting

### Drives Won't Spin Down

If drives remain active after 30+ minutes:

1. **Check for active processes accessing the drives:**
   ```bash
   sudo lsof /mnt/minio-*
   ```

2. **Monitor I/O activity:**
   ```bash
   sudo iotop -o
   ```
   Look for any processes reading/writing to the MinIO drives.

3. **Verify hdparm settings were applied:**
   ```bash
   sudo hdparm -I /dev/disk/by-id/wwn-0x5000c5008a1a78df | grep -i standby
   ```
   Should show `standby after: 1800 seconds` (30 minutes).

4. **Check udev rule exists:**
   ```bash
   cat /etc/udev/rules.d/69-hdparm-spindown.rules
   ```

### Frequent Spin-Ups

If drives spin up and down too frequently:

1. **Review MinIO access logs:**
   ```bash
   sudo journalctl -u minio -f
   ```
   Look for S3 API calls during idle periods.

2. **Consider increasing timeout:**
   Edit `group_vars/nas/main.yml` and increase `minio_disk_spindown_timeout`:
   ```yaml
   minio_disk_spindown_timeout: 480  # 40 minutes
   # or
   minio_disk_spindown_timeout: 720  # 60 minutes
   ```

3. **Check SnapRAID sync schedule:**
   ```bash
   systemctl status minio-snapraid-sync.timer
   ```
   Ensure sync runs only once daily (default: 5 AM).

### Drives Not Spinning Up

If drives fail to spin up when accessed:

1. **Check drive health:**
   ```bash
   sudo smartctl -H /dev/disk/by-id/wwn-0x5000c5008a1a78df
   ```

2. **Manually spin up:**
   ```bash
   sudo hdparm -C /dev/disk/by-id/wwn-0x5000c5008a1a78df
   ```

3. **Check MinIO service status:**
   ```bash
   systemctl status minio
   ```

## Safety & Compatibility

### Data Safety

- **No data risk**: Spin-down only affects power state, not data integrity
- **Automatic recovery**: Drives automatically spin up on access
- **No performance impact**: Modern HDDs handle thousands of spin-up/spin-down cycles

### MinIO Compatibility

- **S3 operations compatible**: MinIO handles spin-up delays gracefully with built-in retries
- **Backup safety**: Drives automatically spin up when accessed by backup jobs
- **No application changes needed**: Transparent to all applications accessing MinIO S3

### Reversibility

To disable disk spin-down:

1. Remove udev rule:
   ```bash
   sudo rm /etc/udev/rules.d/69-hdparm-spindown.rules
   ```

2. Reload udev:
   ```bash
   sudo udevadm control --reload-rules
   ```

3. Reboot (or manually reset hdparm settings):
   ```bash
   sudo hdparm -S 0 /dev/disk/by-id/wwn-0x5000c5008a1a78df
   sudo hdparm -S 0 /dev/disk/by-id/wwn-0x5000c5008a1a7d0f
   ```

## References

- [hdparm man page](https://manpages.debian.org/bookworm/hdparm/hdparm.8.en.html)
- [Debian hdparm package](https://packages.debian.org/bookworm/hdparm)
- [Advanced Power Management (APM) specification](https://en.wikipedia.org/wiki/Advanced_Power_Management)
- [Hard Drive Spin-Down Best Practices](https://wiki.archlinux.org/title/hdparm)
