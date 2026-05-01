#!/usr/bin/env bash
# Reverse of build.sh + install-firmware.sh: remove the patched modules and
# restore any pre-existing MT7902 firmware blobs that were backed up.

set -euo pipefail

INSTALL_DIR="/lib/modules/$(uname -r)/updates/mediatek"
FW_DIR="/lib/firmware/mediatek"
FILES=(
    WIFI_MT7902_patch_mcu_1_1_hdr.bin
    WIFI_RAM_CODE_MT7902_1.bin
)

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must be run as root (try: sudo $0)" >&2
    exit 1
fi

echo ">> removing modules from $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
depmod -a "$(uname -r)"

echo ">> restoring pre-mt7902 firmware backups (if any)"
for f in "${FILES[@]}"; do
    if [ -f "$FW_DIR/$f.pre-mt7902" ]; then
        mv -f "$FW_DIR/$f.pre-mt7902" "$FW_DIR/$f"
        echo "   restored $f"
    fi
done

echo
echo "done. you may want to:"
echo "  rmmod mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null"
echo "  modprobe mt7921e"
echo "to reload the in-tree modules immediately."
