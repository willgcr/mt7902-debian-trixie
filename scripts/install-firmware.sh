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

# Pin to a specific linux-firmware release tag rather than `main` so a
# future upstream firmware update doesn't silently swap the blobs out
# from under us. linux-firmware uses date-based release tags (YYYYMMDD);
# bump LINUX_FW_TAG to take a newer release after testing it.
LINUX_FW_TAG="${LINUX_FW_TAG:-20260410}"
LINUX_FW_RAW="${LINUX_FW_RAW:-https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$LINUX_FW_TAG/mediatek}"
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

command -v curl >/dev/null 2>&1 || { echo "error: curl not installed" >&2; exit 1; }
mkdir -p "$FW_DIR"

# Fetch the three firmware blobs directly. linux-firmware is multi-GB even
# with sparse-checkout; for three ~50 KB files curl is dramatically faster
# than git clone + sparse-checkout, and works against any mirror's raw
# content endpoint (override via LINUX_FW_RAW=...).
echo ">> fetching MT7902 firmware blobs from linux-firmware@$LINUX_FW_TAG"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR/mediatek"
cd "$TMP_DIR"
for f in "${FILES[@]}"; do
    echo "   $f"
    curl -fsSL "$LINUX_FW_RAW/$f" -o "mediatek/$f" \
        || { echo "error: failed to fetch $f from $LINUX_FW_RAW" >&2; exit 1; }
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
