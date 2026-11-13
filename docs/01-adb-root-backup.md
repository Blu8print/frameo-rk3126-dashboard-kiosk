# 1. ADB, root & backup

## Enable ADB

On most of these frames ADB is enabled from the Frameo app:

**Frameo → Settings → About → Beta Program (on) → ADB access (on).**

Then from your computer:

```sh
adb devices          # should show the frame (model rk312x / Frame)
adb shell getprop ro.board.platform      # rk312x
adb shell getprop ro.build.version.release   # 6.0.1
```

Notes seen in the wild:
- A **USB-A-to-USB-C data cable** is often required; some bundled cables are power-only and
  USB-C-to-USB-C may not enumerate.
- `adbd` on these builds often **does not enforce the RSA key** (`ro.adb.secure=1`
  notwithstanding) — a fresh computer may be accepted with no "Allow USB debugging?" prompt. That
  is convenient here but underlines the security warning in the main README.

## Root

The firmware ships `su` (SuperSU `daemonsu`) with **no prompt**:

```sh
adb shell su -c id          # uid=0(root) ...
```

If `su -c` fails, try `su 0 id` (some builds use the `su 0 <cmd>` form). Confirm the shell has
real capabilities and `/system` can be made writable before attempting the `/system` steps:

```sh
adb shell su -c 'cat /proc/self/status | grep CapEff'   # full set, e.g. 0000001fffffffff
adb shell getenforce                                     # Permissive
```

### The daemonsu read-only remount race

SuperSU's `daemonsu` re-mounts `/system` **read-only several times a minute**. So a plain
`mount -o remount,rw /system` can flip back to read-only before your next command runs, and a write
fails with `Read-only file system` even though the flag said `rw`. Every `/system` write in this
repo's scripts therefore **retries** the remount+write until it sticks. If you do it by hand, loop
it:

```sh
adb shell su -c 'n=0; while [ $n -lt 60 ]; do mount -o remount,rw /system; echo x >/system/.p 2>/dev/null && { rm /system/.p; echo RW_OK; break; }; n=$((n+1)); done'
```

## ADB over TCP (optional but recommended)

These frames fight the USB gadget: the Frameo app flips `sys.usb.config` back to plain MTP (and
sometimes `none`) after boot, so USB `adb` can drop. **ADB over TCP sidesteps that entirely** — it
rides WiFi and doesn't depend on `sys.usb.config` at all.

If you have a shell already:

```sh
adb tcpip 5555
adb connect <frame-ip>:5555          # find the IP in your router's DHCP list
```

To make it **permanent and independent of the USB fight**, patch the boot ramdisk so `adbd`
starts unconditionally and binds a TCP port, regardless of USB state:

- In `default.prop`: append `service.adb.tcp.port=5555` (adbd reads this itself at startup).
- In `init.rc`: remove the `disabled` flag from the `service adbd` stanza so it starts with
  `class core` at boot instead of only via the USB property triggers.
- Inject your host key as `/adb_keys` in the ramdisk (your `~/.android/adbkey.pub`) so adbd trusts
  it over TCP with no prompt — important because these frames have SystemUI disabled and never show
  the authorization dialog.

The boot partition on this board is the **KRNL**-wrapped image at **LBA `0x14000`, size `0x7000`
sectors**. Read, patch, and write it back with Rockchip loader mode and
[`rkdeveloptool`](https://github.com/rockchip-linux/rkdeveloptool):

```sh
# Frame in Loader mode (2207:310d). With the Frameo Beta Program on, re-plugging USB often
# enumerates Loader mode automatically; otherwise use the MASKROM fallback:
#   rkdeveloptool db rk3126_loader.bin
rkdeveloptool rl 0x14000 0x7000 boot.img            # read (KEEP THIS as your restore point)
# ... patch boot.img's ramdisk (adbd + tcp port + /adb_keys) ...
rkdeveloptool wl 0x14000 boot-patched.img           # write
rkdeveloptool rl 0x14000 0x7000 readback.img && cmp readback.img boot-patched.img && echo OK
rkdeveloptool rd                                    # reboot
```

> Patched boot images contain **your** ADB public key and the **vendor's** ramdisk — don't publish
> them. This repo documents the method, not the binaries.

## Back up before touching `/system`

With root you can stream everything before `userdata` over ADB (adjust the sector count to your
eMMC; everything before the `userdata`/`UDISK` partition):

```sh
adb exec-out "su -c 'dd if=/dev/block/mmcblk0 bs=1048576 count=<MiB> 2>/dev/null'" \
  | tee >(sha256sum) | gzip -1 > emmc-pre-userdata.img.gz
```

Verify the gzip reads back to the same hash, and re-read a few partitions on-device
(`su -c 'dd ... | md5sum'`) to confirm the capture. **Restoring** needs Loader mode +
`rkdeveloptool` (write the relevant partition back). Keep a copy of stock `boot` and stock
`/system/app/webview/webview.apk` specifically.

→ Next: [2. Upgrade WebView 44 → 106](02-webview-upgrade.md)
