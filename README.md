# AviumUI OnePlus 13 (dodge) Build System

Automated build and packaging for AviumUI Android 16 on the OnePlus 13 (`dodge`), with OrangeFox Recovery flashable ZIP output.

## Features

- **One-command build**: `repo sync` then `./build.sh`
- **Automatic super.img**: Builds dynamic partition super image alongside ROM
- **OrangeFox-ready**: Produces a flashable ZIP with slot-aware installer
- **Raw partition images**: Uses `dd` for maximum compatibility — no payload.bin extraction needed

## Repository Structure

```
├── manifest/
│   └── local_manifest.xml    # Repo local manifest with custom device trees
├── build.sh                  # Main build & package script
├── orangefox-update-binary   # Standalone OrangeFox installer (embedded in build.sh)
└── README.md                 # This file
```

## Quick Start

### 1. Initialize AviumUI Source

```bash
# Create workspace
mkdir -p ~/AviumUI && cd ~/AviumUI

# Initialize repo with AviumUI manifest
repo init -u https://github.com/AviumUI/android_manifests -b avium-16.2

# Add device-specific repositories
curl -L -o .repo/local_manifests/dodge.xml \
  https://raw.githubusercontent.com/spiral009/avium-dodge-build/main/manifest/local_manifest.xml

# Sync (this will take a while)
repo sync -c -j$(nproc) --force-sync --no-clone-bundle --no-tags
```

### 2. Build

```bash
cd ~/AviumUI

# Download build script
curl -L -O https://raw.githubusercontent.com/spiral009/avium-dodge-build/main/build.sh
chmod +x build.sh

# Build (userdebug by default)
./build.sh

# Or build user/release variant
./build.sh user

# Or clean build
./build.sh userdebug --clean
```

### 3. Flash

Transfer the resulting `AviumUI-dodge-YYYYMMDD-*.zip` to your device and flash via **OrangeFox Recovery**:

1. Boot to OrangeFox Recovery
2. Install → Select the ZIP
3. Swipe to flash
4. Reboot system

> **Note**: If you need read-write access to the super partition, flash the [ro2rw](https://github.com/crdroidandroid/android_vendor_ro2rw) module from OrangeFox **after** first boot.

## What's in the ZIP?

| File | Target Partition | Slotted? |
|------|-----------------|----------|
| `boot.img` | `boot` | Yes |
| `init_boot.img` | `init_boot` | Yes |
| `dtbo.img` | `dtbo` | Yes |
| `vendor_boot.img` | `vendor_boot` | Yes |
| `vbmeta*.img` | `vbmeta*` | Yes |
| `super.img` | `super` | **No** |

The installer automatically detects your current A/B slot (`_a` or `_b`) and flashes slotted partitions to the correct slot.

## Custom Repositories

This build uses custom forks with the following modifications:

| Path | Remote | Branch | Notes |
|------|--------|--------|-------|
| `device/oneplus/dodge` | `spiral009/device_oneplus_dodge` | `AviumUI16.2-clean` | Device tree |
| `device/oneplus/sm8750-common` | `spiral009/device_oneplus_sm8750-common` | `AviumUI16.2-clean` | Common tree (tango32 support, VINTF fix) |
| `vendor/oneplus/dodge` | `spiral009/proprietary_vendor_oneplus_dodge` | `AviumUI16.2-clean` | Vendor blobs (arm32 removed) |
| `vendor/oneplus/sm8750-common` | `spiral009/proprietary_vendor_oneplus_sm8750-common` | `AviumUI16.2-clean` | Common vendor |
| `kernel/oneplus/sm8750` | `spiral009/kernel_oneplus_sm8750` | `UwU` | Kernel (MT7601U, DroidSpaces configs) |
| `hardware/oplus` | `spiral009/android_hardware_los_oplus` | `AviumUI16.2-clean` | OPlus hardware HAL |

## Key Modifications

- **tango32 kernel module**: Enables ARM32 binary translation via `tango_translator`
- **ntsync support**: Windows syscall compatibility layer
- **VINTF kernel requirements disabled**: Allows custom kernel without VINTF enforcement
- **SYSVIPC preserved**: Required for LXC/Docker containers (never modify kernel config duplicates)
- **MT7601U WiFi**: USB WiFi adapter support compiled as module
- **BoardConfig**: `BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true` for automatic super.img generation

## Troubleshooting

### Out of memory during build
```bash
./build.sh userdebug  # Use fewer parallel jobs by editing JOBS in build.sh
```

### super.img not found
Make sure `BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true` is set in `device/oneplus/dodge/BoardConfig.mk`. The build script runs `m superimage` as a fallback.

### ZIP too large for recovery
The super.img is ~13GB raw. The script uses `zip -0` (store, no compression). Ensure your recovery partition or USB-OTG has enough space. Stream extraction in the installer prevents RAM exhaustion.

### Slot detection fails
The installer falls back to `_a` if slot cannot be detected. Check `ro.boot.slot_suffix` property after boot.

## Credits

- Base ROM: [AviumUI](https://github.com/AviumUI)
- Device trees: [osm1019](https://github.com/osm1019)
- Kernel: [osm1019](https://github.com/osm1019/kernel_oneplus_sm8750)
- Custom modifications: [spiral009](https://github.com/spiral009)

## License

Apache 2.0 — Same as base Android/LineageOS projects.
