#!/usr/bin/env bash
# Build a patched mt76 driver with MT7902 support against the running kernel
# and install it to /lib/modules/$(uname -r)/updates/mediatek/.
#
# Tested on Debian trixie, kernel 6.12.73+deb13-amd64, on an amd64 system
# with PCI 14c3:7902. Other kernels and host platforms are not validated.
# If your kernel already brings the chip up cleanly (no "Failed to get
# patch semaphore" / "hardware init failed" in dmesg), you do not need this.

set -euo pipefail

MT76_REPO="${MT76_REPO:-https://github.com/openwrt/mt76.git}"
MT76_COMMIT="${MT76_COMMIT:-66067d20}"
BUILD_DIR="${BUILD_DIR:-/tmp/mt76-build}"
# KVER selects which kernel to build against. Defaults to the running kernel
# so live-system use is unchanged; chroot/initramfs/container builders can
# pass KERNEL_VERSION=<kernel-release> to target an installed-but-not-running
# kernel (whose modules dir is at /lib/modules/$KVER/).
KVER="${KERNEL_VERSION:-$(uname -r)}"
INSTALL_DIR="/lib/modules/$KVER/updates/mediatek"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "error: must be run as root (try: sudo $0)" >&2
        exit 1
    fi
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "error: $1 not installed" >&2; exit 1; }
}

require_root
require_tool git
require_tool make
require_tool gcc

KSRC="/lib/modules/$KVER/build"
if [ ! -d "$KSRC" ]; then
    echo "error: kernel headers not found at $KSRC" >&2
    echo "install with: apt install linux-headers-$KVER" >&2
    exit 1
fi

echo ">> cloning mt76 to $BUILD_DIR"
rm -rf "$BUILD_DIR"
git clone "$MT76_REPO" "$BUILD_DIR"
cd "$BUILD_DIR"
git checkout "$MT76_COMMIT"
git log -1 --format='   on commit %h %s'

echo ">> stripping unused chip subdirs and the mt76x02 shared lib"
for d in mt76x0 mt76x2 mt7603 mt7615 mt7915 mt7996 mt7925; do
    rm -rf "$d"
done
rm -f mt76x02_*.c mt76x02_*.h

echo ">> applying patches from $REPO_ROOT/patches/wifi"
for p in "$REPO_ROOT"/patches/wifi/*.patch; do
    echo "   $(basename "$p")"
    git apply "$p"
done

echo ">> building modules"
make -C "$KSRC" M="$BUILD_DIR" clean >/dev/null 2>&1 || true
make -j"$(nproc)" -C "$KSRC" M="$BUILD_DIR" \
    KCFLAGS='-include linux/version.h' modules

echo ">> installing modules to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/mt7921"
install -m 0644 "$BUILD_DIR"/mt76.ko             "$INSTALL_DIR/"
install -m 0644 "$BUILD_DIR"/mt76-connac-lib.ko  "$INSTALL_DIR/"
install -m 0644 "$BUILD_DIR"/mt792x-lib.ko       "$INSTALL_DIR/"
install -m 0644 "$BUILD_DIR"/mt7921/mt7921-common.ko "$INSTALL_DIR/mt7921/"
install -m 0644 "$BUILD_DIR"/mt7921/mt7921e.ko       "$INSTALL_DIR/mt7921/"

echo ">> running depmod"
depmod -a "$KVER"

echo
echo "done. verify with:"
echo "  modinfo mt7921e | grep -E 'filename|alias' | head"
echo "  modinfo mt7921e | grep -m1 'pci:v000014C3d00007902' && echo 'MT7902 in alias table'"
echo
echo "to load now (without reboot):"
echo "  rmmod mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null"
echo "  modprobe mt7921e"
