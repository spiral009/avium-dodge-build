#!/usr/bin/env bash
# =============================================================================
# AviumUI OnePlus 13 (dodge) - Build & Package Script
# =============================================================================
# Builds AviumUI and produces an OrangeFox-flashable package set:
#
#   1) AviumUI-dodge-<date>-<type>-FLASHER.zip  (small: boot-class images +
#      shell installer). Flashes boot/dtbo/vbmeta to BOTH slots, then locates
#      super.img next to the zip and writes it via simg2img.
#   2) super.img  (the dynamic-partition super image, ~8GB).
#
# Why split? OrangeFox's busybox `unzip` cannot reliably read a >4GB ZIP64
# archive on this device (it fails to read the central directory / large
# members, so a single all-in-one zip won't even list its contents). Keeping
# the zip tiny avoids busybox entirely for the big data; super.img is written
# by simg2img directly from the file, which is rock solid.
#
# FLASH: put the FLASHER zip and super.img in the SAME folder on the phone,
#        then OrangeFox > Install > the FLASHER zip > swipe > reboot.
#
# Usage:  ./build.sh [userdebug|user|eng] [--clean] [--package-only]
# Requirements: synced Android source, ~250GB free disk, 16GB+ RAM.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

DEVICE="dodge"
RELEASE="bp4a"
TARGET="lineage_${DEVICE}-${RELEASE}"
PRODUCT_OUT="out/target/product/${DEVICE}"
JOBS=$(nproc)
BUILD_TYPE="userdebug"
CLEAN_BUILD=false
PACKAGE_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --clean|-c)         CLEAN_BUILD=true ;;
        --package-only|-p)  PACKAGE_ONLY=true ;;
        userdebug|user|eng) BUILD_TYPE="$arg" ;;
    esac
done

LUNCH_TARGET="${TARGET}-${BUILD_TYPE}"

echo -e "${BLUE}=== AviumUI build (${LUNCH_TARGET}, jobs ${JOBS}, clean ${CLEAN_BUILD}, pkgonly ${PACKAGE_ONLY}) ===${NC}"

echo -e "${YELLOW}[1/8] Env...${NC}"
[[ -f build/envsetup.sh ]] || { echo -e "${RED}Not in Android source root.${NC}"; exit 1; }
FREE_GB=$(df -BG . | awk 'NR==2 {print $4}' | tr -d 'G')
[[ "$FREE_GB" -ge 50 ]] || { echo -e "${RED}Need >=50GB free, found ${FREE_GB}GB.${NC}"; exit 1; }

echo -e "${YELLOW}[2/8] envsetup...${NC}"
source build/envsetup.sh
# Robust make wrapper (works when `m` function is shadowed in non-login shells).
mk() {
    if [ "$(type -t m 2>/dev/null)" = "function" ]; then m -j"${JOBS}" "$@"
    else build/soong/soong_ui.bash --make-mode TARGET_RELEASE="${RELEASE}" "$@"; fi
}

echo -e "${YELLOW}[3/8] lunch ${LUNCH_TARGET}...${NC}"
lunch "${LUNCH_TARGET}"
export TARGET_RELEASE="${RELEASE}"
echo -e "${GREEN}TARGET_PRODUCT=${TARGET_PRODUCT:-?} RELEASE=${TARGET_RELEASE}${NC}"

if [[ "$CLEAN_BUILD" == true && "$PACKAGE_ONLY" == false ]]; then
    echo -e "${YELLOW}[3.5/8] Clean...${NC}"; mk clean
fi

if [[ "$PACKAGE_ONLY" == false ]]; then
    echo -e "${YELLOW}[4/8] Building ROM (long)...${NC}"; mk bacon
else
    echo -e "${YELLOW}[4/8] --package-only: skip build${NC}"
fi

echo -e "${YELLOW}[5/8] Building super.img...${NC}"
mk superimage
SUPER_IMG="${PRODUCT_OUT}/super.img"
[[ -f "$SUPER_IMG" ]] || { echo -e "${RED}super.img not found${NC}"; exit 1; }
echo -e "${GREEN}super.img: $(du -h "$SUPER_IMG" | cut -f1)${NC}"

echo -e "${YELLOW}[6/8] Collecting boot-class images...${NC}"
STAGING_DIR=$(mktemp -d); trap 'rm -rf "${STAGING_DIR}"' EXIT
IMAGES=(boot.img init_boot.img dtbo.img vendor_boot.img vbmeta.img vbmeta_system.img vbmeta_vendor.img)
for img in "${IMAGES[@]}"; do
    [[ -f "${PRODUCT_OUT}/${img}" ]] && cp "${PRODUCT_OUT}/${img}" "${STAGING_DIR}/${img}" \
        || echo -e "${YELLOW}  missing (non-fatal): ${img}${NC}"
done

echo -e "${YELLOW}[7/8] Writing FLASHER installer...${NC}"
mkdir -p "${STAGING_DIR}/META-INF/com/google/android"
echo '# Flashing handled by update-binary (shell).' \
    > "${STAGING_DIR}/META-INF/com/google/android/updater-script"
cat > "${STAGING_DIR}/META-INF/com/google/android/update-binary" <<'BINARY'
#!/sbin/sh
# AviumUI dodge flasher — boot-class imgs (from this zip) to BOTH slots, then
# super.img (found next to this zip) written via simg2img. No busybox unzip of
# any large member (OFOX busybox cannot handle >4GB zips reliably).
OUTFD="$2"; ZIP="$3"
ui_print(){ echo "ui_print ${1}" >> /proc/self/fd/${OUTFD}; echo "ui_print" >> /proc/self/fd/${OUTFD}; }
abort(){ ui_print "FAILED: ${1}"; exit 1; }
BB=$(command -v busybox 2>/dev/null||true); uz(){ if [ -n "$BB" ]; then "$BB" unzip "$@"; else unzip "$@"; fi; }
have(){ command -v "$1" >/dev/null 2>&1; }
ui_print "========================================"
ui_print "  AviumUI for OnePlus 13 (dodge)"
ui_print "========================================"
ui_print " "
ui_print "Flashing boot/dtbo/vbmeta to BOTH slots..."
for img in boot init_boot dtbo vendor_boot vbmeta vbmeta_system vbmeta_vendor; do
    uz -l "$ZIP" "${img}.img" >/dev/null 2>&1 || continue
    for s in _a _b; do blk="/dev/block/by-name/${img}${s}"; [ -e "$blk" ]||continue
        uz -p "$ZIP" "${img}.img" | dd of="$blk" bs=4M 2>/dev/null; ui_print "  -> ${img}${s}"; done
done
ui_print " "
ui_print "Looking for super.img next to this zip..."
ZD=$(dirname "$ZIP"); SUPER=""
for p in "$ZD/super.img" /sdcard/super.img /sdcard/noksu/super.img /data/super.img /external_sd/super.img; do
    [ -f "$p" ] && { SUPER="$p"; break; }
done
[ -n "$SUPER" ] || abort "super.img not found — put super.img in the same folder as this zip and re-flash."
ui_print "  found: $SUPER"
have simg2img || abort "simg2img not found in recovery"
ui_print "Flashing super (simg2img)... (~1-2 min)"
simg2img "$SUPER" "/dev/block/by-name/super" || abort "simg2img super"
have bootctl && bootctl set-active-boot-slot 0 >/dev/null 2>&1 || true
sync
ui_print " "
ui_print "========================================"
ui_print "  Flash complete. Reboot to System."
ui_print "========================================"
exit 0
BINARY
chmod +x "${STAGING_DIR}/META-INF/com/google/android/update-binary"

echo -e "${YELLOW}[8/8] Packaging...${NC}"
DATE=$(date +%Y%m%d)
ZIP_NAME="AviumUI-dodge-${DATE}-${BUILD_TYPE}-FLASHER.zip"
OUTPUT_ZIP="${PWD}/${ZIP_NAME}"
rm -f "$OUTPUT_ZIP"
( cd "$STAGING_DIR" && zip -r6 "$OUTPUT_ZIP" . )
cp -f "$SUPER_IMG" "${PWD}/super.img"

echo ""
echo -e "${GREEN}=== Build complete ===${NC}"
echo -e "${GREEN}Flasher zip:${NC} ${OUTPUT_ZIP}  ($(du -h "$OUTPUT_ZIP"|cut -f1))"
echo -e "${GREEN}super.img:  ${NC} ${PWD}/super.img  ($(du -h "${PWD}/super.img"|cut -f1))"
echo ""
echo -e "${YELLOW}Flash:${NC} put BOTH (FLASHER zip + super.img) in the same folder on the"
echo -e "       phone, then OrangeFox > Install > the FLASHER zip > swipe > reboot."
