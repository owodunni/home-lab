# Beelink Storage Configuration

Documentation for configuring LUKS-encrypted LVM storage on the Beelink ME Mini N150 for Longhorn distributed storage in the K3s cluster.

## Hardware Overview

**Model:** Beelink ME Mini N150
- **CPU:** Intel N150 (4-core, low power)
- **RAM:** 12-16GB LPDDR5-4800 (soldered)
- **Storage:** 6x M.2 slots (2230/2242/2280) - up to 24TB capacity
- **Network:** Dual 2.5G Ethernet + WiFi 6
- **Role:** Longhorn storage worker node for K3s distributed storage

## Storage Architecture

### Design Decisions

**LUKS Encryption:**
- Full disk encryption for data-at-rest security
- Auto-unlock on boot via key file in `/root/.luks/`
- Key file encrypted with ansible-vault in repository

**LVM Aggregation:**
- Combines all 3x NVMe drives into single storage pool
- Enables future expansion (just add drives and extend volume)
- Longhorn doesn't support sharding across multiple disks

**ext4 Filesystem:**
- Longhorn official recommendation over XFS
- Better stability under network issues (less corruption)
- Required for RWX volumes (longhorn-share-manager)
- Better small file performance (typical k8s workloads)

### Storage Stack

```
3x 2TB NVMe Drives
    ↓
LUKS Encryption (AES-XTS-256)
    ↓
LVM Physical Volumes
    ↓
LVM Volume Group (longhorn-vg)
    ↓
LVM Logical Volume (longhorn-lv, 100%FREE)
    ↓
ext4 Filesystem
    ↓
Mount: /var/lib/longhorn
```

## Setup Instructions

Configuration details are in `group_vars/beelink_nas/main.yml`.

### Prerequisites

1. **Passwordless sudo configured:**
   ```bash
   make beelink-setup
   ```

2. **LUKS key file created and encrypted:**
   ```bash
   # Generate random key
   dd if=/dev/urandom of=group_vars/beelink_nas/luks.key bs=4096 count=1
   chmod 600 group_vars/beelink_nas/luks.key

   # Encrypt with ansible-vault
   uv run ansible-vault encrypt group_vars/beelink_nas/luks.key
   ```

3. **NVMe device identifiers identified:**
   ```bash
   ssh beelink "ls -l /dev/disk/by-id/ | grep nvme"
   # Update group_vars/beelink_nas/main.yml with actual WWN identifiers
   ```

### Running the Playbook

**⚠️ WARNING:** This will **format all NVMe drives** on beelink. All data will be lost.

```bash
make beelink-storage
```

The playbook will:
1. Install cryptsetup and lvm2 packages
2. Copy encrypted LUKS key file to server
3. Initialize LUKS encryption on all NVMe drives
4. Configure `/etc/crypttab` for automatic unlock
5. Create LVM physical volumes, volume group, and logical volume
6. Format with ext4 filesystem
7. Mount to `/var/lib/longhorn` with fstab persistence

**Execution time:** ~5-10 minutes depending on drive initialization

## Verification

```bash
# Check LUKS encryption is active
cryptsetup status /dev/mapper/longhorn1_crypt
# Should show: type: LUKS2, cipher: aes-xts-plain64

# Visual overview - see encryption layer
lsblk -f
# Should show: nvme → crypto_LUKS → LVM2_member → ext4

# Verify mount
df -h /var/lib/longhorn
# Should show: /dev/mapper/longhorn--vg-longhorn--lv mounted, ~5.2T available

# Test auto-unlock on reboot
ssh beelink "sudo reboot"
# After boot, check drives auto-unlocked and mounted
ssh beelink "lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT | grep longhorn"
```

## Troubleshooting

The playbook is fully idempotent. For most issues, re-run:
```bash
make beelink-storage
```

**Manual LUKS unlock (for testing):**
```bash
cryptsetup luksOpen /dev/disk/by-id/nvme-CT2000P310SSD8_24454C177944 longhorn1_crypt \
  --key-file /root/.luks/beelink-luks.key
```

**Check key file permissions:**
```bash
ls -la /root/.luks/beelink-luks.key
# Should be: -rw------- (600) root:root
```

## Expanding Storage

To add additional NVMe drives:
1. Install new drive(s) physically
2. Add to `group_vars/beelink_nas/main.yml`
3. Re-run `make beelink-storage`
4. Use `vgextend` and `lvextend` to expand LVM (see Ansible LVM docs)

## Security Considerations

**Current approach:**
- LUKS encryption with key file in `/root/.luks/beelink-luks.key`
- Auto-unlocks on boot (key readable by root)
- Key encrypted with ansible-vault in repository

**Protects against:**
- ✅ Drive theft (data unreadable without key)
- ✅ Decommissioned drives (data encrypted)
- ❌ Physical root access to running system

For higher security, consider TPM 2.0 sealed keys or network-bound disk encryption (NBDE).

## Next Steps

After storage configuration:
1. Install Longhorn on K3s cluster
2. Configure Longhorn to use beelink as storage node
3. Set storage reservation (recommended: 10% buffer)
4. Create StorageClass for workloads
5. Configure backup schedule to external storage
