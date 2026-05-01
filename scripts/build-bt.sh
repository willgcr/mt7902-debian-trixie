#!/usr/bin/env bash
# Build a patched btmtk driver with MT7902 support against the running kernel
# and install it to /lib/modules/$(uname -r)/updates/bluetooth/.
#
# Tested on Debian trixie, kernel 6.12.73+deb13-amd64, on an amd64 system
# with USB 0e8d:7902 (MediaTek combo Wi-Fi 6 + BT 5.2 chip). Other kernels
# and host platforms are not validated. If your kernel already brings the
# BT chip up cleanly (no "Bluetooth: hciN: Unsupported hardware variant
# (00007902)" in dmesg, hci0 UP RUNNING with a real BD_ADDR), you do not
# need this.

set -euo pipefail

LINUX_STABLE_REPO="${LINUX_STABLE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
BUILD_DIR="${BUILD_DIR:-/tmp/btmtk-build}"
# KVER selects which kernel to build against. Defaults to the running kernel
# so live-system use is unchanged; chroot/initramfs/container builders can
# pass KERNEL_VERSION=<kernel-release> to target an installed-but-not-running
# kernel (whose modules dir is at /lib/modules/$KVER/).
KVER="${KERNEL_VERSION:-$(uname -r)}"
INSTALL_DIR="/lib/modules/$KVER/updates/bluetooth"
# btmtk source tag. Defaults to the stable tag matching the running kernel
# (e.g. 6.12.73+deb13-amd64 -> v6.12.73), so the driver source matches the
# kernel ABI without re-pinning across point releases. Override with
# BTMTK_TAG=v6.12.X if needed.
BASE_VER="$(echo "$KVER" | sed 's/[+-].*//')"
BTMTK_TAG="${BTMTK_TAG:-v$BASE_VER}"
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

echo ">> sparse-cloning linux-stable@$BTMTK_TAG (drivers/bluetooth/) to $BUILD_DIR/src"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/src" "$BUILD_DIR/btmtk"
git clone --depth=1 --branch "$BTMTK_TAG" --no-checkout "$LINUX_STABLE_REPO" "$BUILD_DIR/src"
(
    cd "$BUILD_DIR/src"
    git sparse-checkout init --cone
    git sparse-checkout set drivers/bluetooth
    git checkout
    git log -1 --format='   on tag %D (%h) %s'
)

echo ">> staging btmtk.{c,h} into $BUILD_DIR/btmtk"
cp "$BUILD_DIR/src/drivers/bluetooth/btmtk.c" "$BUILD_DIR/btmtk/"
cp "$BUILD_DIR/src/drivers/bluetooth/btmtk.h" "$BUILD_DIR/btmtk/"

echo ">> writing out-of-tree Makefile"
cat > "$BUILD_DIR/btmtk/Makefile" <<'EOF'
obj-m := btmtk.o
EOF

echo ">> applying patches from $REPO_ROOT/patches/bt"
cd "$BUILD_DIR/btmtk"
for p in "$REPO_ROOT"/patches/bt/*.patch; do
    echo "   $(basename "$p")"
    git apply "$p"
done

echo ">> building module"
make -C "$KSRC" M="$BUILD_DIR/btmtk" clean >/dev/null 2>&1 || true
make -j"$(nproc)" -C "$KSRC" M="$BUILD_DIR/btmtk" modules

echo ">> installing module to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
install -m 0644 "$BUILD_DIR/btmtk/btmtk.ko" "$INSTALL_DIR/btmtk.ko"

echo ">> running depmod"
depmod -a "$KVER"

echo
echo "done. verify with:"
echo "  modinfo btmtk | grep -E 'filename|^firmware' | head"
echo "  modinfo btmtk | grep -m1 BT_RAM_CODE_MT7902 && echo 'MT7902 in firmware list'"
echo
echo "to load now (without reboot):"
echo "  systemctl stop bluetooth"
echo "  rmmod btusb btmtk 2>/dev/null"
echo "  modprobe btusb"
echo "  systemctl start bluetooth"
