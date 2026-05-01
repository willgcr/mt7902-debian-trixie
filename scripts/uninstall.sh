#!/usr/bin/env bash
# Reverse of build-wifi.sh + build-bt.sh + install-firmware.sh: remove the
# patched modules and restore any pre-existing MT7902 firmware blobs that
# were backed up.

set -euo pipefail

# Mirrors the build scripts: defaults to the running kernel; chroot/initramfs
# callers can override via KERNEL_VERSION=<kernel-release> to target a
# non-running one.
KVER="${KERNEL_VERSION:-$(uname -r)}"
WIFI_INSTALL_DIR="/lib/modules/$KVER/updates/mediatek"
BT_INSTALL_DIR="/lib/modules/$KVER/updates/bluetooth"
FW_DIR="/lib/firmware/mediatek"
FILES=(
    WIFI_MT7902_patch_mcu_1_1_hdr.bin
    WIFI_RAM_CODE_MT7902_1.bin
    BT_RAM_CODE_MT7902_1_1_hdr.bin
)

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must be run as root (try: sudo $0)" >&2
    exit 1
fi

echo ">> removing wifi modules from $WIFI_INSTALL_DIR"
rm -rf "$WIFI_INSTALL_DIR"

echo ">> removing bt module from $BT_INSTALL_DIR/btmtk.ko"
rm -f "$BT_INSTALL_DIR/btmtk.ko"
# only remove the directory if we created it and it's now empty
rmdir --ignore-fail-on-non-empty "$BT_INSTALL_DIR" 2>/dev/null || true

depmod -a "$KVER"

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
echo "  systemctl stop bluetooth && rmmod btusb btmtk 2>/dev/null && modprobe btusb && systemctl start bluetooth"
echo "to reload the in-tree modules immediately."
