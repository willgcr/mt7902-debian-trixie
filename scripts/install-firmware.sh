#!/usr/bin/env bash
# Install MT7902 Wi-Fi and Bluetooth firmware blobs from the upstream
# linux-firmware tree into /lib/firmware/mediatek/. Pre-existing same-named
# files are backed up with a .pre-mt7902 suffix.
#
# Why these specific blobs: on the test hardware, the linux-firmware blobs
# load and run cleanly. A previously-installed set of MT7902 Wi-Fi firmware
# files (different byte counts) loaded but caused the chip to stall on the
# 14th MCU command after init (recurring "Message 00020001 timeout" reset
# loop). The MT7902 BT blob was simply missing from the test machine and
# is required before the patched btmtk module can complete the firmware
# download handshake. This script does not bundle the blobs; it fetches
# them from kernel.org.

set -euo pipefail

LINUX_FW_REPO="${LINUX_FW_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git}"
TMP_DIR="${TMP_DIR:-/tmp/linux-firmware-mt7902}"
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

command -v git >/dev/null 2>&1 || { echo "error: git not installed" >&2; exit 1; }
mkdir -p "$FW_DIR"

echo ">> sparse-cloning linux-firmware mediatek/ subdir to $TMP_DIR"
rm -rf "$TMP_DIR"
git clone --depth=1 --no-checkout "$LINUX_FW_REPO" "$TMP_DIR"
cd "$TMP_DIR"
git sparse-checkout init --cone
git sparse-checkout set mediatek
git checkout

echo ">> verifying blobs are present"
for f in "${FILES[@]}"; do
    if [ ! -f "mediatek/$f" ]; then
        echo "error: $f not found in linux-firmware tree" >&2
        echo "       (linux-firmware may not yet ship MT7902 blobs at this commit;" >&2
        echo "        try a newer linux-firmware checkout)" >&2
        exit 1
    fi
done

echo ">> installing to $FW_DIR (existing files backed up with .pre-mt7902 suffix)"
for f in "${FILES[@]}"; do
    if [ -f "$FW_DIR/$f" ] && [ ! -L "$FW_DIR/$f" ] && [ ! -f "$FW_DIR/$f.pre-mt7902" ]; then
        mv "$FW_DIR/$f" "$FW_DIR/$f.pre-mt7902"
        echo "   backed up old $f"
    fi
    install -m 0644 "mediatek/$f" "$FW_DIR/$f"
    echo "   installed $f ($(stat -c %s "$FW_DIR/$f") bytes)"
done

echo
echo "done."
