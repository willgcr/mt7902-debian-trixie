# mt7902-debian-trixie

Out-of-tree mt76 build that adds **MediaTek MT7902** Wi-Fi support on Debian
trixie's stock kernel, plus a script to install the matching firmware from
the upstream linux-firmware tree.

## Status

Everything below is what we observed on one machine. We make no claims about
hardware or kernel versions we didn't test.

**Tested working:**

- Hardware: an amd64 system with this Wi-Fi chip (PCI ID `14c3:7902`,
  ASIC revision `79020000`). The bundled Windows INF identifies it as
  *"MediaTek Wi-Fi 6 MT7902LEN Wireless LAN Card"*.
- OS: Debian trixie live image.
- Kernel: `6.12.73+deb13-amd64`.
- Result after applying this fix: `wlan` interface appears, `iw scan` returns
  real APs, association/connection succeeds.

## What it actually fixes

Two independent problems on the same chip:

### 1. The driver

Stock `mt7921e` in kernel 6.12.73 has no PCI alias for `0x7902` and no
MT7902-specific bringup. Force-binding it via `new_id` makes the driver
attach but the chip immediately fails the MCU patch handshake:

```
mt7921e 0000:01:00.0: ASIC revision: 79020000
mt7921e 0000:01:00.0: Failed to get patch semaphore
mt7921e 0000:01:00.0: hardware init failed
```

The four MT7902-specific commits in the upstream `openwrt/mt76` tree
(`eaa09af1`, `5ee90425`, `772c51c2`, `c3d74293` — PCIe device, MCU support,
DMA layout, IRQ-map quirk) provide the right bringup. We pin to commit
`66067d20` (the next commit after that group) and backport its build to
6.12 with two small kernel-API compat patches:

- `patches/0001-makefile-build-only-mt7921.patch` — drops `-Werror` and
  the obj-y entries for chip families this repo doesn't build (`mt76x0`,
  `mt76x2`, `mt7603`, `mt7615`, `mt7915`, `mt7996`, `mt7925`, the USB/SDIO
  bus glue, and the `mt76x02` shared lib). The build script also
  `rm -rf`s those subdirectories before applying patches.
- `patches/0002-backport-mac80211-and-timer-api-to-6.12.patch` —
  - reverts two `timer_container_of(...)` calls to `from_timer(...)` in
    `mt792x_core.c` (the upstream tree assumes the kernel 6.16 rename;
    6.12 still has the old name);
  - drops the extra `int radio_idx` / `unsigned int link_id` parameter
    from six mac80211 callbacks (`mt76_get_txpower`, `mt76_get_antenna`,
    `mt792x_set_coverage_class`, `mt7921_config`,
    `mt7921_set_rts_threshold`, `mt7921_set_antenna`). The 6.13 kernel
    added that parameter for Wi-Fi 7 multi-link operation; the 6.12
    `ieee80211_ops` struct doesn't have it. The parameter is unused
    inside these callbacks for this chip family.

### 2. The firmware

With the patched driver, the chip booted and reported a HW/SW version,
but then printed `WM Firmware Version: ____000000` (an empty version
field) and started failing every ~14 MCU commands with
`Message 00020001 (seq N) timeout`, recovering, and looping.

`/lib/firmware/mediatek/` on the test machine had MT7902 Wi-Fi blobs of
different byte counts than the ones in the upstream linux-firmware tree.
After replacing them with the linux-firmware blobs, the timeout loop
stopped and the chip became stable. We don't know why the
previously-installed blobs misbehaved with this driver — only that the
swap fixed it.

`scripts/install-firmware.sh` fetches the linux-firmware copies and
installs them, backing up any existing same-named files with a
`.pre-mt7902` suffix.

## Use

You don't need this if your kernel already brings the chip up cleanly:
no `Failed to get patch semaphore` or `hardware init failed` in `dmesg`,
a `wlan` interface in `iw dev`, and `iw scan` returns APs. We only tested
on a kernel where those symptoms were present.

### Build deps (Debian trixie)

```
sudo apt install linux-headers-$(uname -r) git build-essential
```

### Identify your hardware

```
lspci -nnk | grep -A3 -iE 'network|wireless'
```

Look for `14c3:7902`. If you see a different MediaTek device ID, this
repo is not for you.

### Install

```
sudo ./scripts/build.sh             # builds mt76 + installs to /lib/modules/.../updates/mediatek/
sudo ./scripts/install-firmware.sh  # fetches MT7902 blobs from linux-firmware
```

Then either reboot, or reload the modules without rebooting:

```
sudo rmmod mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null
sudo modprobe mt7921e
```

### Verify

```
dmesg | grep mt7921e | tail
iw dev
```

You should see `wlanN`, no `Failed to get patch semaphore`, no recurring
`Message 00020001 timeout`. A `sudo iw dev wlanN scan` should return APs.

### Uninstall

```
sudo ./scripts/uninstall.sh
```

Removes the modules from `/lib/modules/$(uname -r)/updates/mediatek/` and
restores any firmware files this repo replaced (kept as
`*.pre-mt7902` siblings).

## Reporting issues

Useful info to include in any issue:

```
lspci -nnk -s $(lspci -d 14c3: | awk '{print $1; exit}')
uname -r
modinfo mt7921e | grep -E 'filename|^alias' | head
dmesg | grep -E 'mt7921e|mt76|mt792x' | tail -50
```

## License

BSD 3-Clause Clear, matching the upstream openwrt/mt76 tree the patches
are derived from. See `LICENSE`.

## Acknowledgments

The actual MT7902 driver work is the upstream `openwrt/mt76` contributors'.
This repo only backports the build to a kernel that doesn't yet ship those
patches, and points at the right firmware.
