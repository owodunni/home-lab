# Pi CM5 Boot Configuration Reference

This document provides comprehensive guidance for configuring Raspberry Pi CM5 boot settings using our Ansible automation, inspired by geerlingguy's elegant approach.

## Overview

The Raspberry Pi Compute Module 5 (CM5), launched in November 2024, delivers Raspberry Pi 5 performance in an embedded form factor. Our configuration focuses on headless operation with aggressive power optimization and selective PCIe enablement.

## Configuration File Location

- **Pi CM5/Pi 5**: `/boot/firmware/config.txt`
- **Legacy Pi models**: `/boot/config.txt`

## Our Configuration Approach

We use geerlingguy's proven pattern: simple `lineinfile` tasks with variable-driven configuration arrays for maximum flexibility and maintainability.

### Role Structure
```
roles/pi_cm5_config/
├── defaults/main.yml    # Configuration arrays and defaults
├── tasks/main.yml       # Simple lineinfile tasks with with_items
├── handlers/main.yml    # Reboot notification handler
└── meta/main.yml        # Role metadata
```

## Configuration Categories

### Base Settings (`pi_cm5_base_config`)

Essential settings for headless Pi CM5 operation:

| Setting | Value | Purpose | Reference |
|---------|-------|---------|-----------|
| `arm_64bit=1` | Enable 64-bit mode | Essential for CM5 performance | [Official docs](https://www.raspberrypi.com/documentation/computers/config_txt.html) |
| `gpu_mem=64` | Minimal GPU memory | Power savings for headless | Lower values reduce available system RAM |
| `camera_auto_detect=0` | Disable camera detection | Power savings | Prevents camera module detection on boot |
| `display_auto_detect=0` | Disable display detection | Power savings | Prevents HDMI display detection |

### Power Optimization (`pi_cm5_power_config`)

Aggressive power-saving configurations providing ~200mW+ savings:

| Setting | Power Savings | Purpose | Reference |
|---------|---------------|---------|-----------|
| `dtoverlay=disable-wifi` | ~183mW | Disable WiFi radio | [Forum discussion](https://forums.raspberrypi.com/viewtopic.php?t=361037) |
| `dtoverlay=disable-bt` | Additional savings | Disable Bluetooth radio | Same overlay system |
| `dtoverlay=vc4-kms-v3d,noaudio` | Minor savings | Disable HDMI audio | Append `,noaudio` to existing overlay |

### PCIe Configuration (`pi_cm5_pcie_config`)

Conditional PCIe enablement based on node role:

| Setting | Purpose | Node Type | Reference |
|---------|---------|-----------|-----------|
| `dtparam=pciex1=on` | Enable PCIe for M.2 | NAS nodes | [PCIe documentation](https://www.jeffgeerling.com/blog/2023/testing-pcie-on-raspberry-pi-5) |
| `dtparam=pciex1=off` | Disable for power savings | Cluster nodes | Explicit disable for power optimization |

**Aliases**: `dtparam=nvme` is equivalent to `dtparam=pciex1`

## Playbook Usage

### Base Configuration
```bash
make pi-base-config    # Configure base settings + power optimization
```

Applies to: All nodes (cluster + NAS)
- Essential headless settings
- Aggressive power optimization
- WiFi/Bluetooth/LED disable

### Storage Configuration
```bash
make pi-storage-config  # Configure PCIe based on node group
```

Applies PCIe settings based on group membership:
- **NAS nodes**: PCIe enabled for M.2 controllers
- **Cluster nodes**: PCIe disabled for power savings

### Complete Configuration
```bash
make pi-full-config    # Apply both base and storage configs
```

## Group Variables

Our configuration uses group-specific variables for different hardware requirements:

### Control Plane Nodes (`group_vars/control_plane.yml`)
```yaml
# Compute nodes - maximum power optimization
pi_cm5_pcie_enabled: false  # No M.2 storage needed
```

### NAS Node (`group_vars/nas.yml`)
```yaml
# Storage node - PCIe required for M.2 controller
pi_cm5_pcie_enabled: true   # Required for M.2 SATA support
```

## Power Consumption Impact

Based on research and community testing:

| Feature | Power Reduction | Notes |
|---------|----------------|-------|
| WiFi disable | ~183mW | Significant savings for battery/solar |
| Bluetooth disable | ~10-20mW | Additional radio savings |
| HDMI audio disable | Minor | Reduces audio processing |
| PCIe disable | Variable | Depends on controller activity |
| **Total estimated** | **~200mW+** | Meaningful for 24/7 operation |

## Validation and Safety

### Automatic Validation
- Hardware verification (aarch64 + BCM processor) - can be skipped with `pi_cm5_skip_validation: true`
- Config file syntax validation after changes
- Automatic backup creation with timestamps
- Automatic backup restoration if validation fails

### Manual Validation
After configuration, verify settings:
```bash
# Check config.txt content
sudo cat /boot/firmware/config.txt | grep -E "(arm_64bit|gpu_mem|dtoverlay|dtparam)"

# Verify backup creation
ls -la /boot/firmware/config.txt.backup-*

# Check hardware detection (after reboot)
vcgencmd get_config arm_64bit
vcgencmd get_config gpu_mem
```

### Recovery
If configuration causes boot issues:
1. Mount SD card on another system
2. Restore from backup: `cp config.txt.backup-[timestamp] config.txt`
3. Or edit config.txt to remove problematic settings

## Troubleshooting

### Common Issues

**Config changes not applied**:
- Verify `/boot/firmware/config.txt` (not `/boot/config.txt`)
- Ensure settings are under `[all]` section
- Reboot required for all changes

**LED settings not working**:
- Firmware versions may require different parameters
- Try legacy format if current doesn't work
- Check specific CM5 documentation

**PCIe not working**:
- Verify `dtparam=pciex1=on` is present
- Check if device is detected: `lspci`
- Some devices auto-enable PCIe when detected

### Useful Commands
```bash
# View current GPU memory
vcgencmd get_mem gpu

# Check PCIe devices
lspci

# Monitor power consumption (if hardware supports)
vcgencmd measure_volts
vcgencmd measure_temp

# View all current config
vcgencmd get_config int
```

## References

- [Raspberry Pi config.txt documentation](https://www.raspberrypi.com/documentation/computers/config_txt.html)
- [Pi 5 PCIe testing by Jeff Geerling](https://www.jeffgeerling.com/blog/2023/testing-pcie-on-raspberry-pi-5)
- [LED control guide](https://www.jeffgeerling.com/blogs/jeff-geerling/controlling-pwr-act-leds-raspberry-pi)
- [Power optimization forum discussion](https://forums.raspberrypi.com/viewtopic.php?t=361037)
- [geerlingguy's Raspberry Pi role](https://github.com/geerlingguy/ansible-role-raspberry-pi)

## Configuration History

Our implementation evolution:
1. **Initial**: Complex monolithic role with 134 lines
2. **Geerlingguy inspiration**: Adopted simple lineinfile + variable arrays pattern
3. **Current**: Clean, maintainable, CM5-optimized configuration

This approach provides the flexibility of geerlingguy's pattern while targeting Pi CM5 specific optimizations.
