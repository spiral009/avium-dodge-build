#!/usr/bin/env bash
# =============================================================================
# AviumUI OnePlus 13 (dodge) - Build & Package Script
# =============================================================================
# Builds AviumUI and packages it into an OrangeFox Recovery flashable ZIP.
#
# Flashing model: boot-class images -> BOTH slots; super.img is split into
# <2GB chunks and reassembled on-device, because OrangeFox R12's busybox unzip
# cannot extract a >4GB ZIP64 member (it aborts with "short read"). The chunks
# are reassembled to a temp file and written to the super partition via simg2img.
#
# Usage:
#   ./build.sh [userdebug|user|eng] [--clean] [--package-only]
#     --package-only  Skip ROM build; just (re)build super.img + package the zip.
#
# Requirements: synced Android source, ~250GB free disk, 16GB+ RAM.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

DEVICE="dodge"
RELEASE="bp4a"                       # A16 release config for this tree
TARGET="lineage_${DEVICE}-${RELEASE}"
PRODUCT_OUT="out/target/product/${DEVICE}"
JOBS=$(nproc)
BUILD_TYPE="userdebug"
CLEAN_BUILD=false
PACKAGE_ONLY=false
SUPER_CHUNK="1500M"                  # each chunk < 2GB => busybox-unzip safe

for arg in "$@"; do
    case "$arg" in
        --clean|-c)         CLEAN_BUILD=true ;;
        --package-only|-p)  PACKAGE_ONLY=true ;;
        userdebug|user|eng) BUILD_TYPE="$arg" ;;
    esac
done

LUNCH_TARGET="${TARGET}-${BUILD_TYPE}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  AviumUI Build Script for OnePlus 13  ${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Target:${NC} ${LUNCH_TARGET}  ${BLUE}Jobs:${NC} ${JOBS}  ${BLUE}Clean:${NC} ${CLEAN_BUILD}  ${BLUE}PackageOnly:${NC} ${PACKAGE_ONLY}"
echo ""

# --- env checks --------------------------------------------------------------
echo -e "${YELLOW}[1/8] Checking environment...${NC}"
[[ -f build/envsetup.sh ]] || { echo -e "${RED}Not in Android source root.${NC}"; exit 1; }
FREE_GB=$(df -BG . | awk 'NR==2 {print $4}' | tr -d 'G')
[[ "$FREE_GB" -ge 50 ]] || { echo -e "${RED}Need >=50GB free, found ${FREE_GB}GB.${NC}"; exit 1; }
echo -e "${GREEN}OK (${FREE_GB}GB free)${NC}"

# --- build env + lunch -------------------------------------------------------
echo -e "${YELLOW}[2/8] Setting up build environment...${NC}"
source build/envsetup.sh
# Robust make wrapper: prefer the `m` function, else soong_ui (works in
# non-interactive / CI shells where `m` may be shadowed by a stray binary).
mk() {
    if [ "$(type -t m 2>/dev/null)" = "function" ]; then
        m -j"${JOBS}" "$@"
    else
        build/soong/soong_ui.bash --make-mode TARGET_RELEASE="${RELEASE}" "$@"
    fi
}

echo -e "${YELLOW}[3/8] lunch ${LUNCH_TARGET}...${NC}"
lunch "${LUNCH_TARGET}"
export TARGET_RELEASE="${RELEASE}"
echo -e "${GREEN}TARGET_PRODUCT=${TARGET_PRODUCT:-?} RELEASE=${TARGET_RELEASE}${NC}"

if [[ "$CLEAN_BUILD" == true && "$PACKAGE_ONLY" == false ]]; then
    echo -e "${YELLOW}[3.5/8] Cleaning...${NC}"; mk clean
fi

# --- build ROM ---------------------------------------------------------------
if [[ "$PACKAGE_ONLY" == false ]]; then
    echo -e "${YELLOW}[4/8] Building ROM (long)...${NC}"
    mk bacon
    echo -e "${GREEN}ROM build complete${NC}"
else
    echo -e "${YELLOW}[4/8] --package-only: skipping ROM build${NC}"
fi

# --- super.img ---------------------------------------------------------------
echo -e "${YELLOW}[5/8] Building super.img...${NC}"
mk superimage
SUPER_IMG="${PRODUCT_OUT}/super.img"
[[ -f "$SUPER_IMG" ]] || { echo -e "${RED}super.img not found${NC}"; exit 1; }
echo -e "${GREEN}super.img: $(du -h "$SUPER_IMG" | cut -f1)${NC}"

# --- collect images ----------------------------------------------------------
echo -e "${YELLOW}[6/8] Collecting images...${NC}"
STAGING_DIR=$(mktemp -d); trap 'rm -rf "${STAGING_DIR}"' EXIT
IMAGES=(boot.img init_boot.img dtbo.img vendor_boot.img vbmeta.img vbmeta_system.img vbmeta_vendor.img)
MISSING=()
for img in "${IMAGES[@]}"; do
    if [[ -f "${PRODUCT_OUT}/${img}" ]]; then cp "${PRODUCT_OUT}/${img}" "${STAGING_DIR}/${img}"; else MISSING+=("$img"); fi
done
[[ ${#MISSING[@]} -gt 0 ]] && echo -e "${YELLOW}Missing (non-fatal): ${MISSING[*]}${NC}"

echo -e "${YELLOW}      splitting super.img into ${SUPER_CHUNK} chunks...${NC}"
split -b "${SUPER_CHUNK}" -d -a 2 "$SUPER_IMG" "${STAGING_DIR}/super.img."
NLIST=$(cd "$STAGING_DIR" && ls super.img.?? | sed 's/super\.img\.//' | sort | tr '\n' ' ')
echo -e "${GREEN}      super chunks: ${NLIST}${NC}"

# --- OrangeFox installer -----------------------------------------------------
echo -e "${YELLOW}[7/8] Writing OrangeFox installer...${NC}"
mkdir -p "${STAGING_DIR}/META-INF/com/google/android"
echo '# Flashing handled by update-binary (shell). See that file.' \
    > "${STAGING_DIR}/META-INF/com/google/android/updater-script"
# Non-quoted heredoc so ${NLIST} expands at build time; runtime vars escaped as \$.
cat > "${STAGING_DIR}/META-INF/com/google/android/update-binary" <<BINARY
#!/sbin/sh
# AviumUI dodge installer — A/B + dynamic-super (chunked super, busybox-unzip-safe).
OUTFD="\$2"; ZIP="\$3"
ui_print(){ echo "ui_print \${1}" >> /proc/self/fd/\${OUTFD}; echo "ui_print" >> /proc/self/fd/\${OUTFD}; }
abort(){ ui_print "FAILED: \${1}"; exit 1; }
BB=\$(command -v busybox 2>/dev/null||true); uz(){ if [ -n "\$BB" ]; then "\$BB" unzip "\$@"; else unzip "\$@"; fi; }
have(){ command -v "\$1" >/dev/null 2>&1; }
ui_print "========================================"
ui_print "  AviumUI for OnePlus 13 (dodge)"
ui_print "========================================"
ui_print " "
ui_print "Flashing boot/dtbo/vbmeta to both slots..."
for img in boot init_boot dtbo vendor_boot vbmeta vbmeta_system vbmeta_vendor; do
    uz -l "\$ZIP" "\${img}.img" >/dev/null 2>&1 || continue
    for s in _a _b; do blk="/dev/block/by-name/\${img}\${s}"; [ -e "\$blk" ]||continue
        uz -p "\$ZIP" "\${img}.img" | dd of="\$blk" bs=4M 2>/dev/null; ui_print "  -> \${img}\${s}"; done
done
TMP=""
for d in /data /sdcard /external_sd; do [ -d "\$d" ]||continue
    fk=\$(df -k "\$d" 2>/dev/null|awk 'NR==2{print \$4}'); [ -n "\$fk" ]&&[ "\$fk" -gt 8000000 ]&&{ TMP="\$d"; break; }; done
[ -n "\$TMP" ]||abort "no temp dir with >8GB free"
ui_print "Reassembling super.img in \$TMP ..."
rm -f "\$TMP/super.img"
for idx in ${NLIST}; do
    uz -p "\$ZIP" "super.img.\${idx}" >> "\$TMP/super.img" || abort "extract chunk \${idx}"
    ui_print "  + chunk \${idx}"
done
have simg2img || abort "simg2img not found in recovery"
ui_print "Flashing super (simg2img)..."
simg2img "\$TMP/super.img" "/dev/block/by-name/super" || abort "simg2img super"
rm -f "\$TMP/super.img"
have bootctl && bootctl set-active-boot-slot 0 >/dev/null 2>&1 || true
sync
ui_print " "
ui_print "========================================"
ui_print "  Flash complete. Reboot to system."
ui_print "========================================"
exit 0
BINARY
chmod +x "${STAGING_DIR}/META-INF/com/google/android/update-binary"

# --- package -----------------------------------------------------------------
echo -e "${YELLOW}[8/8] Packaging flashable ZIP...${NC}"
DATE=$(date +%Y%m%d)
ZIP_NAME="AviumUI-dodge-${DATE}-${BUILD_TYPE}-OFOX.zip"
OUTPUT_ZIP="${PWD}/${ZIP_NAME}"
rm -f "$OUTPUT_ZIP"
( cd "$STAGING_DIR" && zip -r1 "$OUTPUT_ZIP" . )

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Output:${NC} ${OUTPUT_ZIP}"
echo -e "${GREEN}Size:${NC}   $(du -h "$OUTPUT_ZIP" | cut -f1)"
echo ""
echo -e "${YELLOW}Flash:${NC} OrangeFox > Install > select the ZIP > swipe > reboot."
