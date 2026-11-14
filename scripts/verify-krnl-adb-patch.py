#!/usr/bin/env python3
"""Report whether a KRNL-wrapped boot image carries the ADB-over-TCP patch set.

Read-only. Use it to check an image *before* flashing it, and to check what a
partition read back off the device is *actually* running:

    rkdeveloptool rl 0x14000 0x7000 boot-live.img
    ./verify-krnl-adb-patch.py boot-live.img

That is how you rule the boot image in or out without a risky write. It
reports the three things that must all hold for ADB to come up on these frames
(see docs/01-adb-root-backup.md for why each is needed):

  [1] /adb_keys exists in the ramdisk        - no authorization dialog to tap,
                                               SystemUI is disabled
  [2] default.prop sets service.adb.tcp.port - adbd binds a TCP listener itself
  [3] the init.rc adbd stanza has no
      `disabled` flag                        - adbd starts at boot instead of
                                               only via USB property triggers

A KRNL image is: b"KRNL" + uint32 LE payload length + payload (a gzip'd newc
cpio ramdisk) + uint32 LE Rockchip CRC32. The newc cpio walk here follows the
one in Wes Bos's krnl-add-adb-key.py (wesbos/photo-frame-dashboard, MIT),
which is the companion tool that *writes* /adb_keys.

Usage:  ./verify-krnl-adb-patch.py <boot.img> [more.img ...]
"""
import gzip
import os
import struct
import sys

TRAILER = b"TRAILER!!!"


def align4(n):
    return (n + 3) & ~3


def parse_cpio(raw):
    """Return [(name, file_data)] up to and including the trailer entry."""
    entries, off = [], 0
    while True:
        hdr = raw[off:off + 110]
        if hdr[:6] != b"070701":
            sys.exit(f"not a newc cpio entry at offset {off}")
        fields = [int(hdr[6 + i * 8:14 + i * 8], 16) for i in range(13)]
        filesize, namesize = fields[6], fields[11]
        name = raw[off + 110:off + 110 + namesize - 1]
        dstart = align4(off + 110 + namesize)
        entries.append((name, raw[dstart:dstart + filesize]))
        off = align4(dstart + filesize)
        if name == TRAILER:
            return entries


def check(path):
    print("=" * 64)
    print(os.path.basename(path))
    print("=" * 64)
    blob = open(path, "rb").read()
    if blob[:4] != b"KRNL":
        print("  !! no KRNL magic - not a wrapped boot image for this board")
        return False

    payload_len = struct.unpack("<I", blob[4:8])[0]
    files = dict(parse_cpio(gzip.decompress(blob[8:8 + payload_len])))
    ok = True

    keys = files.get(b"adb_keys")
    print(f"  [1] /adb_keys   : {f'present ({len(keys)} bytes)' if keys else 'MISSING'}")
    ok &= bool(keys)

    prop = files.get(b"default.prop", b"")
    tcp = [l for l in prop.split(b"\n") if b"service.adb.tcp.port" in l]
    usb = [l for l in prop.split(b"\n") if b"persist.sys.usb.config" in l]
    print(f"  [2] tcp port    : {tcp[0].decode().strip() if tcp else 'MISSING'}")
    print(f"      usb.config  : {usb[0].decode().strip() if usb else '(unset)'}")
    ok &= bool(tcp)

    lines = files.get(b"init.rc", b"").split(b"\n")
    for i, line in enumerate(lines):
        if line.startswith(b"service adbd"):
            disabled = any(x.strip() == b"disabled" for x in lines[i:i + 8])
            print(f"  [3] adbd stanza : {'DISABLED - adbd will not start at boot' if disabled else 'unconditional (good)'}")
            ok &= not disabled
            break
    else:
        print("  [3] adbd stanza : not found in init.rc")
        ok = False

    print(f"  => {'ADB over TCP should come up' if ok else 'NOT fully patched'}")
    return ok


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(0 if all(check(p) for p in sys.argv[1:]) else 1)
