# mt7902-debian-trixie

Out-of-tree builds that add **MediaTek MT7902** Wi-Fi *and* Bluetooth
support on Debian trixie's stock kernel, plus a script to install the
matching firmware from the upstream linux-firmware tree.

## Status

Everything below is what we observed on one machine. We make no claims about
hardware or kernel versions we didn't test.

**Tested working:**

- Hardware: an amd64 system with this combo Wi-Fi 6 + BT 5.2 chip
  (PCI ID `14c3:7902` for the Wi-Fi side, USB ID `0e8d:7902` for the
  Bluetooth side, ASIC revision `79020000`). The bundled Windows INF
  identifies the Wi-Fi side as *"MediaTek Wi-Fi 6 MT7902LEN Wireless LAN
  Card"*.
- OS: Debian trixie live image.
- Kernel: `6.12.73+deb13-amd64`.
- Result after applying these fixes: `wlan` interface appears, `iw scan`
  returns real APs, association/connection succeeds; `hci0` comes up
  with a real BD address, BlueZ scans return nearby devices.

## What it actually fixes

Four independent problems on the same chip — two on the Wi-Fi side, two
on the Bluetooth side. Each fix is independent; you can install just the
Wi-Fi half, just the BT half, or both.

### 1. The Wi-Fi driver

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

### 2. The Wi-Fi firmware

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

`scripts/install-firmware.sh` fetches the linux-firmware copies (Wi-Fi
*and* Bluetooth — see below) and installs them, backing up any existing
same-named files with a `.pre-mt7902` suffix.

### 3. The Bluetooth driver

Stock `btmtk` in kernel 6.12.73 has cases for hardware variants 0x7922,
0x7925, and 0x7961 in `btmtk_usb_setup()`, but not 0x7902. The chip
exposes USB ID `0e8d:7902`; `btusb` attaches via the generic
`USB_VENDOR_AND_INTERFACE_INFO(0x0e8d, 0xe0, 0x01, 0x01)` match and
hands off to btmtk, which then reads the chip ID and bails out:

```
Bluetooth: hci0: Unsupported hardware variant (00007902)
```

`hci0` ends up `DOWN`, BD address `00:00:00:00:00:00`. Upstream Linux
already adds MT7902 to the variant switch and defines a matching
`FIRMWARE_MT7902` for the firmware filename; the change isn't (yet)
in the 6.12.x stable cycle. We backport just those additions
(`patches/bt/0001-add-mt7902-variant.patch` — three hunks across
`btmtk.c` and `btmtk.h`) and build `btmtk.ko` out-of-tree against the
running kernel headers. No changes to `btmtk_setup_firmware_79xx()`
or `btmtk_fw_get_filename()` are needed: both already handle 0x79xx
dev_ids generically, and the filename for MT7902
(`BT_RAM_CODE_MT7902_1_1_hdr.bin`) follows the existing 79xx naming
convention.

### 4. The Bluetooth firmware

With the patched driver, the chip is recognized, but the firmware
download fails because `BT_RAM_CODE_MT7902_1_1_hdr.bin` simply isn't
in `/lib/firmware/mediatek/` on the test machine — only the 7922 and
7961 BT blobs ship by default. The blob is in the upstream
linux-firmware tree; `scripts/install-firmware.sh` installs it
alongside the Wi-Fi blobs.

## Use

You don't need this if your kernel already brings the chip up cleanly:
no `Failed to get patch semaphore` / `hardware init failed` in `dmesg`,
a `wlan` interface in `iw dev`, `iw scan` returns APs, no
`Bluetooth: hci0: Unsupported hardware variant (00007902)` in `dmesg`,
`hci0` is `UP RUNNING` with a real BD address. We only tested on a
kernel where those symptoms were present.

### Build deps (Debian trixie)

```
sudo apt install linux-headers-$(uname -r) git build-essential
```

### Identify your hardware

```
lspci -nnk | grep -A3 -iE 'network|wireless'   # Wi-Fi side: expect 14c3:7902
lsusb | grep 0e8d:7902                          # BT side
```

Look for `14c3:7902` and/or `0e8d:7902`. If you see a different MediaTek
device ID, this repo is not for you.

### Install

The Wi-Fi and Bluetooth halves are independent — install only the one(s)
you need:

```
sudo ./scripts/build-wifi.sh        # builds mt76 + installs to /lib/modules/.../updates/mediatek/
sudo ./scripts/build-bt.sh          # builds patched btmtk + installs to /lib/modules/.../updates/bluetooth/
sudo ./scripts/install-firmware.sh  # fetches MT7902 Wi-Fi + BT blobs from linux-firmware
```

Then either reboot, or reload the modules without rebooting.

Wi-Fi:

```
sudo rmmod mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null
sudo modprobe mt7921e
```

Bluetooth:

```
sudo systemctl stop bluetooth
sudo rmmod btusb btmtk 2>/dev/null
sudo modprobe btusb
sudo systemctl start bluetooth
```

### Verify

Wi-Fi:

```
dmesg | grep mt7921e | tail
iw dev
```

You should see `wlanN`, no `Failed to get patch semaphore`, no recurring
`Message 00020001 timeout`. A `sudo iw dev wlanN scan` should return APs.

Bluetooth:

```
dmesg | grep -iE 'bluetooth|btmtk' | tail
hciconfig -a
```

You should see `Bluetooth: hciN: HW/SW Version: 0x...` (firmware
download succeeded), no `Unsupported hardware variant (00007902)`, and
`hciN` reported as `UP RUNNING` with a real BD address (not all-zeroes)
and Manufacturer `MediaTek, Inc. (70)`. A short
`bluetoothctl scan le` (or `scan on` for Classic) should return nearby
devices.

### Uninstall

```
sudo ./scripts/uninstall.sh
```

Removes the patched modules from
`/lib/modules/$(uname -r)/updates/mediatek/` and
`/lib/modules/$(uname -r)/updates/bluetooth/`, and restores any firmware
files this repo replaced (kept as `*.pre-mt7902` siblings).

## Reporting issues

Useful info to include in any issue:

```
lspci -nnk -s $(lspci -d 14c3: | awk '{print $1; exit}')
lsusb -t | grep -B1 -A1 btusb
uname -r
modinfo mt7921e | grep -E 'filename|^alias' | head
modinfo btmtk  | grep -E 'filename|^firmware' | head
dmesg | grep -E 'mt7921e|mt76|mt792x' | tail -50
dmesg | grep -iE 'bluetooth|btmtk|btusb' | tail -30
```

## License

The Wi-Fi-side patches and `build-wifi.sh` are BSD 3-Clause Clear, matching
the upstream `openwrt/mt76` tree they derive from. The Bluetooth-side patch
in `patches/bt/` derives from the Linux kernel's `drivers/bluetooth/btmtk.{c,h}`
and inherits its **ISC** license (per the SPDX header in those files);
`build-bt.sh` and the rest of the repo follow BSD 3-Clause Clear. See
`LICENSE`.

## Acknowledgments

The actual MT7902 Wi-Fi work is the upstream `openwrt/mt76` contributors';
the Bluetooth variant entry is taken from upstream Linux mainline btmtk.
This repo only backports those builds to a kernel that doesn't yet ship
the changes, and points at the right firmware.
