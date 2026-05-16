#!/usr/bin/env bash
# =============================================================================
# AviumUI OnePlus 13 (dodge) - Build & Package Script
# =============================================================================
# This script automates building AviumUI ROM and packaging it into an
# OrangeFox Recovery flashable ZIP with raw partition images.
#
# Usage:
#   ./build.sh [userdebug|user|eng] [--clean]
#
# Requirements:
#   - Android build environment set up (repo sync completed)
#   - At least 200GB free disk space
#   - 16GB+ RAM recommended
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DEVICE="dodge"
TARGET="lineage_${DEVICE}-bp4a"
PRODUCT_OUT="out/target/product/${DEVICE}"
JOBS=$(nproc)
BUILD_TYPE="${1:-userdebug}"
CLEAN_BUILD=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --clean|-c)
            CLEAN_BUILD=true
            ;;
        userdebug|user|eng)
            BUILD_TYPE="$arg"
            ;;
    esac
done

# Validate build type
if [[ ! "$BUILD_TYPE" =~ ^(userdebug|user|eng)$ ]]; then
    echo -e "${RED}Error: Invalid build type '$BUILD_TYPE'. Use userdebug, user, or eng.${NC}"
    exit 1
fi

LUNCH_TARGET="${TARGET}-${BUILD_TYPE}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  AviumUI Build Script for OnePlus 13  ${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Device:${NC}    ${DEVICE}"
echo -e "${BLUE}Target:${NC}    ${LUNCH_TARGET}"
echo -e "${BLUE}Jobs:${NC}      ${JOBS}"
echo -e "${BLUE}Clean:${NC}     ${CLEAN_BUILD}"
echo ""

# =============================================================================
# Environment Checks
# =============================================================================

echo -e "${YELLOW}[1/8] Checking environment...${NC}"

if [[ ! -f "build/envsetup.sh" ]]; then
    echo -e "${RED}Error: Not in Android source root. Please run from ROM source directory.${NC}"
    exit 1
fi

if ! command -v repo &> /dev/null; then
    echo -e "${RED}Error: 'repo' not found in PATH.${NC}"
    exit 1
fi

# Check disk space (need at least 50GB free)
FREE_GB=$(df -BG . | awk 'NR==2 {print $4}' | tr -d 'G')
if [[ "$FREE_GB" -lt 50 ]]; then
    echo -e "${RED}Error: Insufficient disk space. Need at least 50GB free, found ${FREE_GB}GB.${NC}"
    exit 1
fi

echo -e "${GREEN}Environment OK${NC}"

# =============================================================================
# Source Build Environment
# =============================================================================

echo -e "${YELLOW}[2/8] Setting up build environment...${NC}"

source build/envsetup.sh

echo -e "${GREEN}Build environment loaded${NC}"

# =============================================================================
# Lunch
# =============================================================================

echo -e "${YELLOW}[3/8] Running lunch ${LUNCH_TARGET}...${NC}"

lunch "${LUNCH_TARGET}"

echo -e "${GREEN}Lunch complete${NC}"

# =============================================================================
# Clean (if requested)
# =============================================================================

if [[ "$CLEAN_BUILD" == true ]]; then
    echo -e "${YELLOW}[3.5/8] Cleaning build...${NC}"
    m clean
    echo -e "${GREEN}Clean complete${NC}"
fi

# =============================================================================
# Build ROM
# =============================================================================

echo -e "${YELLOW}[4/8] Building ROM (this will take a while)...${NC}"

m -j"${JOBS}"

echo -e "${GREEN}ROM build complete${NC}"

# =============================================================================
# Build super.img
# =============================================================================

echo -e "${YELLOW}[5/8] Building super.img...${NC}"

m superimage

SUPER_IMG="${PRODUCT_OUT}/super.img"
if [[ ! -f "$SUPER_IMG" ]]; then
    echo -e "${RED}Error: super.img not found at ${SUPER_IMG}${NC}"
    exit 1
fi

SUPER_SIZE=$(du -h "$SUPER_IMG" | cut -f1)
echo -e "${GREEN}super.img built: ${SUPER_SIZE}${NC}"

# =============================================================================
# Collect Images
# =============================================================================

echo -e "${YELLOW}[6/8] Collecting images for packaging...${NC}"

STAGING_DIR=$(mktemp -d)
trap "rm -rf ${STAGING_DIR}" EXIT

# Images to include in the flashable ZIP
IMAGES=(
    "boot.img"
    "init_boot.img"
    "dtbo.img"
    "vendor_boot.img"
    "vbmeta.img"
    "vbmeta_system.img"
    "vbmeta_vendor.img"
    "super.img"
)

MISSING_IMAGES=()
for img in "${IMAGES[@]}"; do
    src="${PRODUCT_OUT}/${img}"
    if [[ -f "$src" ]]; then
        cp -v "$src" "${STAGING_DIR}/${img}"
    else
        MISSING_IMAGES+=("$img")
    fi
done

if [[ ${#MISSING_IMAGES[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Warning: Missing images (non-fatal): ${MISSING_IMAGES[*]}${NC}"
fi

# =============================================================================
# Create OrangeFox update-binary
# =============================================================================

echo -e "${YELLOW}[7/8] Creating OrangeFox update-binary...${NC}"

mkdir -p "${STAGING_DIR}/META-INF/com/google/android"

cat > "${STAGING_DIR}/META-INF/com/google/android/update-binary" << 'EOF'
#!/sbin/sh
# AviumUI OnePlus 13 (dodge) OrangeFox Installer
# Auto-detects slot and flashes all images via dd

OUTFD="$2"
ZIP="$3"

ui_print() {
    echo "ui_print $1" >> /proc/self/fd/${OUTFD}
    echo "ui_print" >> /proc/self/fd/${OUTFD}
}

ui_print "========================================"
ui_print "  AviumUI for OnePlus 13 (dodge)"
ui_print "========================================"
ui_print ""

# Detect slot
SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
if [ -z "$SLOT" ]; then
    SLOT=$(cat /proc/cmdline | grep -o 'androidboot.slot_suffix=[^ ]*' | cut -d= -f2)
fi
if [ -z "$SLOT" ]; then
    SLOT="_a"
fi
ui_print "Detected slot: ${SLOT}"
ui_print ""

# Extract and flash each image
TMPDIR=/tmp/avium_install
mkdir -p "$TMPDIR"
cd "$TMPDIR"

# List of slot-aware partitions (super is NOT slotted)
SLOT_AWARE="boot init_boot dtbo vendor_boot vbmeta vbmeta_system vbmeta_vendor"

for img in boot.img init_boot.img dtbo.img vendor_boot.img vbmeta.img vbmeta_system.img vbmeta_vendor.img; do
    partition="${img%.img}"
    
    # Check if partition is slotted
    if echo "$SLOT_AWARE" | grep -qw "$partition"; then
        target="${partition}${SLOT}"
    else
        target="$partition"
    fi
    
    ui_print "Flashing ${img} -> ${target}..."
    
    # Stream extract and flash
    unzip -p "$ZIP" "$img" | dd of="/dev/block/by-name/${target}" bs=4M status=none
    
    if [ $? -eq 0 ]; then
        ui_print "  OK"
    else
        ui_print "  FAILED!"
    fi
done

# Flash super (not slotted, large - stream to avoid OOM)
ui_print "Flashing super.img (this may take a while)..."
unzip -p "$ZIP" "super.img" | dd of="/dev/block/by-name/super" bs=8M status=none
if [ $? -eq 0 ]; then
    ui_print "  OK"
else
    ui_print "  FAILED!"
fi

# Sync to ensure writes complete
sync

ui_print ""
ui_print "========================================"
ui_print "  Flash complete!"
ui_print "========================================"
ui_print "Reboot to system when ready."
ui_print "If you need RW super, flash ro2rw"
ui_print "module from OrangeFox after first boot."
ui_print "========================================"

exit 0
EOF

chmod +x "${STAGING_DIR}/META-INF/com/google/android/update-binary"

# =============================================================================
# Package ZIP
# =============================================================================

echo -e "${YELLOW}[8/8] Packaging flashable ZIP...${NC}"

DATE=$(date +%Y%m%d)
ZIP_NAME="AviumUI-dodge-${DATE}-${BUILD_TYPE}.zip"
OUTPUT_DIR="${PWD}"
OUTPUT_ZIP="${OUTPUT_DIR}/${ZIP_NAME}"

# Use zip -0 (store, no compression) for large images
cd "$STAGING_DIR"
zip -r0 "$OUTPUT_ZIP" .

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Output:${NC} ${OUTPUT_ZIP}"
echo -e "${GREEN}Size:${NC}   $(du -h "$OUTPUT_ZIP" | cut -f1)"
echo ""
echo -e "${YELLOW}Flash instructions:${NC}"
echo "  1. Boot to OrangeFox Recovery"
echo "  2. Install > Select ${ZIP_NAME}"
echo "  3. Swipe to flash"
echo "  4. Reboot system"
echo ""
echo -e "${YELLOW}Optional:${NC} Flash ro2rw module if you need RW super partition"
