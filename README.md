# Frameo RK3126 → dashboard kiosk

Turn a **Frameo-branded digital photo frame built on the Rockchip RK3126 (`rk312x`), Android
6.0.1** into a full-screen web **dashboard kiosk** that boots straight into a web page of your
choice — with a modern browser engine, a daily screen on/off schedule, and the vendor launcher
replaced.

This is a complete, reproducible write-up of getting one such frame unlocked and repurposed:
ADB + root, a WebView engine upgrade (Chromium **44 → 106**), the missing modern root
certificates, and a small native kiosk app that is set as the Home launcher.

> **Search terms / this is for you if** your frame reports `ro.board.platform=rk312x`,
> `ro.product.cpu.abi=armeabi-v7a`, Android **6.0.1** (API 23), and ships the **Frameo** app
> (`net.frameo.frame`) with a stock **WebView 44.0.2403.119**. Rockchip USB IDs seen:
> loader `2207:310d`, ADB `2207:0006`.

---

## ⚠️ Read this first — security limits

These frames **cannot be made secure**. Before putting one on your network:

- **Any app can get root with no prompt.** The firmware ships a `su` (SuperSU `daemonsu`) with no
  manager app, so nothing asks for approval. Install only software you trust.
- **The OS is end-of-life.** Android 6.0.1, last security patch 2016, SELinux permissive. WebView
  106 and its engine get **no more updates** — it is the newest build that runs on Android 6.
- **Vendor apps may phone home.** Some builds ship Adups FOTA and other vendor agents; one related
  RK3126 build was found running a hidden root network agent (`/system/bin/iotv`). Check what runs
  on yours.
- **Do not sign into primary Google/Apple/bank accounts.** Use a dedicated account or a dashboard
  you host yourself, and keep the frame on a guest/IoT VLAN.

This repo documents compatibility with an old OS; it is not an endorsement of exposing these
devices to untrusted networks.

---

## What you get

| | |
|---|---|
| **ADB + root** | Reliable `adb` (USB and/or over WiFi/TCP), root via the shipped `su` |
| **WebView 44 → 106** | Modern Chromium engine so a current web app actually renders (CSS Grid, ES modules, `fetch`, flexbox, service workers) |
| **Modern CA roots** | Let's Encrypt **ISRG Root X1/X2** added so HTTPS sites validate on Android 6 |
| **Kiosk app** | Full-screen WebView launcher (Wes Bos's **Home HQ**) patched to run on API 23, plus a **daily screen on/off schedule** and a **screensaver toggle** |
| **Recovery tooling** | Scripts to find the frame when DHCP moves it, and to verify a boot image actually carries the ADB patch before you flash it |
| **Boot to dashboard** | Kiosk set as the Home launcher, replacing Frameo, so a power-cycle lands on your dashboard |

---

## Step 0 — Confirm it's the same hardware

Plug in over USB (Frameo **Settings → About → Beta Program → ADB access** enables ADB on most
units), then:

```sh
adb shell getprop ro.board.platform      # rk312x
adb shell getprop ro.product.cpu.abi     # armeabi-v7a
adb shell getprop ro.build.version.release   # 6.0.1
adb shell dumpsys package com.android.webview | grep versionName   # 44.0.2403.119
adb shell su -c id                       # uid=0(root)  (ships rooted, no prompt)
```

If `ro.board.platform` is not `rk312x`, **stop** — this guide's WebView binary and `/system`
assumptions won't match. (Frames sold under the same name ship different boards: RK3326,
Allwinner A33/A133, etc. Check the SoC, not the brand.)

**Back up before writing anything to `/system`.** With root you can stream the firmware over ADB;
restoring needs Rockchip loader mode and [`rkdeveloptool`](https://github.com/rockchip-linux/rkdeveloptool).
See [docs/01-adb-root-backup.md](docs/01-adb-root-backup.md).

---

## The steps

1. **[ADB, root & backup](docs/01-adb-root-backup.md)** — enable ADB, confirm root, optionally set
   up **ADB over TCP** (survives the frame's USB-gadget quirks), and back up `/system`.
2. **[Upgrade WebView 44 → 106](docs/02-webview-upgrade.md)** — the stock engine (Chromium 44,
   2015) can't render modern web apps. Replace the system WebView in `/system/app/webview`.
   Script: [`scripts/webview-44-to-106.sh`](scripts/webview-44-to-106.sh).
3. **[Add modern CA roots](docs/03-letsencrypt-roots.md)** — Android 6's trust store predates
   Let's Encrypt; without ISRG Root X1/X2 most HTTPS sites fail to validate.
   Script: [`scripts/add-letsencrypt-roots.sh`](scripts/add-letsencrypt-roots.sh).
4. **[Build, install & configure the kiosk](docs/04-kiosk-and-launcher.md)** — build the patched
   kiosk APK, set your dashboard URL, configure the screen schedule, **stop the screen going dark
   after 30 minutes**, and make it the Home launcher so it boots to your dashboard.
5. **[Loader mode & getting ADB back](docs/05-loader-mode-and-recovery.md)** — reaching Rockchip
   loader mode reliably, reading/patching/restoring the boot partition, and recovering ADB when
   the frame drops off the network.
   Scripts: [`scripts/find-frame.sh`](scripts/find-frame.sh),
   [`scripts/verify-krnl-adb-patch.py`](scripts/verify-krnl-adb-patch.py).

Each `/system` step is reversible; every doc lists the undo.

---

## The kiosk app

[`kiosk/`](kiosk/) is **Home HQ** by Wes Bos (from
[wesbos/photo-frame-dashboard](https://github.com/wesbos/photo-frame-dashboard), MIT) with the
changes needed for this frame. See [kiosk/README.md](kiosk/README.md) to build it. Our additions:

- **Runs on Android 6 (API 23).** The upstream build called `ServiceWorkerController` (API 24+)
  unconditionally and crashed on launch; it's now guarded behind a version check.
- **Daily screen on/off schedule.** An `AlarmManager` fires a manifest receiver that does a *true*
  display off/on via root (`input keyevent 26`/`224`) — an unprivileged app can't sleep the display
  itself, but these frames grant root freely. Default **08:00 on / 22:00 off**, configurable by
  intent extra.
- **Screensaver toggle.** The idle dim-overlay screensaver can be switched off (the schedule
  replaces it).

```sh
# Point it at your dashboard
adb shell am start -n com.wesbos.homehq/.MainActivity --es url https://your-dashboard/

# Screen schedule (minutes resolution), disable the screensaver
adb shell am start -n com.wesbos.homehq/.MainActivity \
  --ei screen_on_hour 8 --ei screen_on_min 0 \
  --ei screen_off_hour 22 --ei screen_off_min 0 \
  --ez screensaver false

# Turn the schedule off entirely (screen stays on 24/7)
adb shell am start -n com.wesbos.homehq/.MainActivity --ez screen_schedule false
```

The default URL baked into this repo is Wes Bos's public demo dashboard
(`https://home-dashboard.wesbos.workers.dev`); set your own with the `url` extra above.

---

## Loader mode & recovering ADB

Rockchip **loader mode** (USB `2207:310d`) is the out-of-band path: raw partition read/write with
[`rkdeveloptool`](https://github.com/rockchip-linux/rkdeveloptool), before Android exists. It is
how the boot ramdisk gets patched for ADB over TCP, and how you restore a frame you broke.

**Reaching it reliably** — hot-replugging USB on a running frame (even with Frameo's Beta Program
on) is inconsistent. What works every time is a cold boot with the cable already attached:

```sh
# 1. unplug the frame's POWER entirely  2. connect the USB data cable to your computer
# 3. power the frame back on            4. poll - it can take a full 50-60 seconds
until lsusb -d 2207: ; do sleep 2; done
rkdeveloptool ld      # must print: Loader
rkdeveloptool rci     # ALWAYS confirm real comms before any read/write (16-byte chip info)
```

A recessed **pinhole button**, if your unit has one, drops straight to the loader — but confirm
what yours does first; a pinhole on consumer hardware is sometimes a factory reset.

Two outputs that look like failures but are **normal**: `db` → `The device does not support this
operation!` (a loader is already running — expected when `rci` works) and `ppt` → `Not found any
partition table!` (this board uses rkparameter, not GPT — use LBA offsets).

Boot lives at LBA **`0x14000`**, length **`0x7000`** sectors:

```sh
rkdeveloptool rl 0x14000 0x7000 boot.img.stock   # read - keep as your restore point
./scripts/verify-krnl-adb-patch.py boot.img.stock # check the 3 things ADB needs
rkdeveloptool wl 0x14000 boot-patched.img        # write
rkdeveloptool rd                                 # boot it
```

**Lost ADB over WiFi? Don't reach for loader mode yet.** `No route to host` is an ARP-level
failure — the frame isn't answering at all — and the usual causes are mundane:

```sh
lsusb -d 2207:                 # anything listed = it's in LOADER mode, not booted → rkdeveloptool rd
./scripts/find-frame.sh 20     # DHCP moved it? sweep for ADB, 20 rounds covers the ~50-60s boot
```

Only then suspect the image — and **verify instead of reflashing blind**: read the live partition
back and compare it. A 14 MiB read takes seconds; a needless write adds risk for no information.
Full detail, including a troubleshooting table: **[docs/05](docs/05-loader-mode-and-recovery.md)**.

---

## The screen goes dark after 30 minutes

Not Frameo, and not the kiosk — it's stock Android's display inactivity timeout, set to
**30 minutes** (`screen_off_timeout=1800000`). Nothing in the kiosk holds a wake lock, and a
wall-mounted frame gets no touch input, so the timer just expires. It only starts happening after
you replace Frameo, because the Frameo app held the screen on itself.

```sh
adb shell settings put system screen_off_timeout 2147483647    # ~24.8 days, effectively never
adb shell settings put global stay_on_while_plugged_in 7       # stay awake whenever powered
```

Both persist across reboots, and **neither breaks the nightly screen schedule** — a stay-awake
device still honours an explicit `keyevent 26` (tested: display slept and stayed off, `224` woke
it). Adding `FLAG_KEEP_SCREEN_ON` to the app would *not* be safe here: it holds a screen-bright
wake lock that fights the schedule. See [docs/04](docs/04-kiosk-and-launcher.md#the-screen-goes-dark-after-30-minutes)
for how to tell which of Frameo / screensaver / schedule / wake lock / timeout is actually
turning your panel off.


## Good to know

- **WebView 106 is a 2022 engine.** It lacks `oklch()`, `color-mix()`, CSS nesting and `:has()`.
  Tailwind v4's default colors (OKLCH) break; build your dashboard for Chrome 106.
- **AlarmManager alarms don't survive a reboot** — the kiosk re-arms the schedule every time it
  starts, which is why making it the Home app (so it launches at boot) matters.
- **Screen wake:** while the display is off via `keyevent 26`, touching the panel does **not** wake
  it on these frames; use `input keyevent 224` (the schedule and ADB both can).
- **Timezone** over ADB (Android 6): `su -c 'setprop persist.sys.timezone Europe/Amsterdam;
  service call alarm 3 s16 Europe/Amsterdam'`, then restart the kiosk.

## Credits & license

- Kiosk app: **Home HQ** © Wes Bos — [wesbos/photo-frame-dashboard](https://github.com/wesbos/photo-frame-dashboard) (MIT).
- The WebView 106 binary is LineageOS's prebuilt `com.android.webview`
  ([android_external_chromium-webview_prebuilt_arm](https://github.com/LineageOS/android_external_chromium-webview_prebuilt_arm)),
  downloaded and verified by the script — not redistributed here.
- This repo (docs, scripts, kiosk patches): **MIT**, see [LICENSE](LICENSE).

No vendor firmware, boot images, or proprietary APKs are included.
