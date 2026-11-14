# 5. Rockchip Loader mode & getting ADB back

Loader mode is the frame's out-of-band access path: the SoC talks to your
computer over USB before Android exists, so you can read and write raw
partitions with [`rkdeveloptool`](https://github.com/rockchip-linux/rkdeveloptool).
It is how you patch the boot ramdisk for ADB over TCP ([doc 1](01-adb-root-backup.md)),
and how you restore a frame whose `/system` or boot image you broke.

It is also the thing people reach for too early. **Read
["Is ADB actually broken?"](#is-adb-actually-broken) first** — most "I lost ADB"
cases are a moved DHCP lease or a frame that simply is not booted, and loader
mode is irrelevant to both.

---

## Is ADB actually broken?

`adb connect` failing with **`No route to host`** is an ARP-level failure: the
frame is not answering on the network *at all*. That is almost never a broken
boot patch. Work down this list before touching loader mode:

1. **Is the frame booted?** A frame in loader mode or powered off is not on the
   network, so every probe fails and looks exactly like dead ADB. Check first:

   ```sh
   lsusb -d 2207:     # anything listed = loader mode, NOT booted
   ```

   If it is in loader mode, just boot it: `rkdeveloptool rd`.

2. **Wait ~50–60s after boot.** `adbd` comes up late on these frames.

3. **Look for a moved IP.** These frames are on DHCP.

   ```sh
   ./scripts/find-frame.sh 20          # retries 20x while it finishes booting
   FRAME_MAC=aa:bb:cc:dd:ee:ff ./scripts/find-frame.sh   # label yours in the output
   ```

   Record your frame's WiFi MAC (`adb shell ip link show wlan0`) once, while
   you *can* reach it — it turns a future hunt into a lookup. A DHCP
   reservation on your router avoids the problem entirely.

4. **Only then suspect the image** — and verify it rather than reflashing
   blind, see [Verify before you write](#verify-before-you-write).

> A worked example: a frame that "lost ADB over WiFi" had been sitting in
> loader mode the whole time. A full subnet sweep found nothing, which looked
> like confirmation that the patch had died. The boot partition read back
> byte-identical to the known-good patched image, and the frame reappeared on
> its *original* IP ~50s after `rkdeveloptool rd`. Nothing had been wrong.

---

## Reaching loader mode

The frame shows up as USB ID **`2207:310d`**.

```sh
lsusb -d 2207:
# Bus 001 Device 012: ID 2207:310d Fuzhou Rockchip Electronics Company RK3126 in Mask ROM mode
```

> `lsusb` prints **"in Mask ROM mode"** for `310d` from its ID database. That
> label is misleading: `310d` here is the **Loader**, not raw Mask ROM.
> `rkdeveloptool ld` is authoritative — it prints `Loader`.

### What works

**A. The pinhole button** (fastest, if your unit has one). With the frame
powered, press the recessed pinhole with a paperclip; the screen goes blank and
the frame enumerates as `2207:310d`.

> Check what your unit's pinhole does before relying on it. On these RK3126
> frames it drops to the Rockchip loader, but a recessed pinhole on consumer
> hardware is sometimes a **factory reset** instead — which would wipe your
> WiFi config and dashboard settings. If you are unsure, use method B.

**B. Cold boot with the cable already attached** (reliable, no button needed):

1. **Fully power the frame off** — unplug its power adapter. Not screen-off,
   not idle.
2. **Connect the USB data cable to your computer first.**
3. **Power the frame back on.**
4. Poll for it — this can take up to **50–60 seconds**, so don't give up early:

   ```sh
   until lsusb -d 2207: ; do sleep 2; done; rkdeveloptool ld
   ```

### What does *not* work reliably

Hot-replugging the USB cable while the frame is already running — including
with Frameo's **Settings → About → Beta Program** enabled — only enumerated
loader mode *inconsistently* on the unit this was written against. If you have
seen that advice (including in [doc 1](01-adb-root-backup.md)), treat it as a
lucky shortcut, not the procedure.

### Permissions

`rkdeveloptool` needs write access to the USB device node. On some systems the
node is already world-writable and **no `sudo` is needed** — check before
assuming:

```sh
ls -l /dev/bus/usb/001/012      # the Bus/Device from lsusb
```

Otherwise install the udev rule shipped with rkdeveloptool
(`99-rk-rockusb.rules`) into `/etc/udev/rules.d/`, or run it with `sudo`.

---

## Confirm the session before you touch anything

`ld` reporting `Loader` only means the device enumerated. **Confirm real
communication with `rci` before any read or write:**

```sh
rkdeveloptool ld       # DevNo=1  Vid=0x2207,Pid=0x310d  ...  Loader
rkdeveloptool rci      # Chip Info: 41 32 31 33 ...   (16 bytes)
rkdeveloptool rfi      # Flash Info: Manufacturer, size, block/page size
```

Two things that look like errors but are **normal**:

| Output | Meaning |
|---|---|
| `rkdeveloptool db rk3126_loader.bin` → `The device does not support this operation!` | Expected **if `rci` works**. `db` only applies to raw Mask ROM; a loader is already running, so it is correctly refused. You do not need `db`. |
| `rkdeveloptool ppt` → `Not found any partition table!` | Expected. This board uses an **rkparameter** table, not GPT. Use explicit LBA offsets (below). |

**If `rci`/`rfi`/`rl` all fail even though `ld` says `Loader`,** the session has
gone stale. Don't keep retrying commands against a dead session — fully power
cycle the frame and start again.

---

## Reading, patching and writing boot

The boot partition on this board is the **KRNL**-wrapped image at LBA
**`0x14000`**, length **`0x7000`** sectors (14 MiB).

```sh
# 1. Read it. KEEP THIS - it is your restore point.
rkdeveloptool rl 0x14000 0x7000 boot.img.stock

# 2. Patch the ramdisk: /adb_keys + service.adb.tcp.port + undisable adbd (doc 1)

# 3. Verify the patched image BEFORE writing it
./scripts/verify-krnl-adb-patch.py boot-patched.img

# 4. Write, read back, compare
rkdeveloptool wl 0x14000 boot-patched.img
rkdeveloptool rl 0x14000 0x7000 readback.img
cmp readback.img boot-patched.img && echo WRITE_OK

# 5. Boot it
rkdeveloptool rd
```

Restore stock the same way: `rkdeveloptool wl 0x14000 boot.img.stock && rkdeveloptool rd`.

### Verify before you write

If ADB is unreachable and you suspect the image, **read the live partition and
check it** — don't reflash on assumption:

```sh
rkdeveloptool rl 0x14000 0x7000 boot-live.img
./scripts/verify-krnl-adb-patch.py boot-live.img
md5sum boot-live.img boot-patched.img     # identical => the image is not your problem
```

A 14 MiB read takes seconds and rules the boot image in or out. Writing when
the image was already correct just adds risk for no information.

> Patched boot images contain **your** ADB public key and the **vendor's**
> ramdisk — keep them local, don't publish them. This repo documents the
> method, not the binaries (`*.img` is in `.gitignore`).

---

## After `rd`: getting back on ADB

`rkdeveloptool rd` prints `Reset Device OK.` and the frame boots normally.
Then:

```sh
./scripts/find-frame.sh 20        # ~50-60s for adbd; 20 rounds covers it
adb shell su -c id                # uid=0(root)
```

If it comes back on the same IP, `adb connect <ip>:5555` is enough.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `adb connect` → `No route to host` | Frame not on the network. Check `lsusb -d 2207:` (loader mode), then [find a moved IP](#is-adb-actually-broken). |
| Nothing on the subnet at all | Frame powered off, still booting, in loader mode, or on a different SSID/VLAN than your computer. |
| `lsusb` shows `2207:310d` as "Mask ROM mode" | Cosmetic `lsusb` label. `rkdeveloptool ld` says `Loader`. |
| `ld` says `Loader` but every command fails | Stale loader session. Power cycle the frame fully and retry. |
| `db` → `does not support this operation` | Normal when a loader is already running. Skip `db`. |
| `ppt` → `Not found any partition table!` | Normal — rkparameter, not GPT. Use LBA offsets. |
| Loader mode never appears | Use cold-boot method B: power off fully, cable first, then power on, and poll for a full 60s. |
| `rkdeveloptool` permission errors | Install `99-rk-rockusb.rules`, or `sudo`. |

---

← Back: [4. Build, install & configure the kiosk](04-kiosk-and-launcher.md) ·
See also: [1. ADB, root & backup](01-adb-root-backup.md)
