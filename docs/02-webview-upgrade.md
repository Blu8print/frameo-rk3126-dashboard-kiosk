# 2. Upgrade WebView 44 → 106

## Why

The stock system WebView is **Chromium 44.0.2403.119** (2015). A modern web app (Vite/PWA, ES
modules, CSS Grid, `fetch`, async/await) **renders blank or broken** on it — the page's HTML may
load (the tab title even updates) while the module scripts are silently ignored. WebView
**106.0.5249.126** is the newest build that still runs on Android 6 (API 23) and renders current
sites fine.

Quick way to see the problem before fixing it: open your dashboard in the stock Browser
(`com.android.browser`) and screenshot it with `adb shell screencap`. A blank body (or a
`Certificate error`, see [doc 3](03-letsencrypt-roots.md)) is the symptom.

## Do it

Back up `/system` first ([doc 1](01-adb-root-backup.md)). Then:

```sh
scripts/webview-44-to-106.sh [adb-serial]
adb reboot        # IMPORTANT: reboot before opening any WebView
```

The script downloads the pinned LineageOS prebuilt `com.android.webview` 106.0.5249.126
(armeabi-v7a), verifies its SHA-256, and replaces `/system/app/webview` in place — keeping a
`webview.apk.bak` of the stock 44 for undo.

### The two traps this handles

1. **Compressed native libs.** WebView 106 stores `libwebviewchromium.so` (and friends)
   compressed. **Android 6 does not extract native libs for a `/system` app**, so if you swap only
   the APK, `dumpsys` reports version 106 but the engine fails to load at runtime (`dlopen failed`).
   The script extracts `lib/armeabi-v7a/*.so` from the APK and places them, uncompressed, in
   `/system/app/webview/lib/arm/`.
2. **The daemonsu read-only remount race** (see [doc 1](01-adb-root-backup.md)) — every write
   retries until it sticks.

### Why a file swap, not `adb install`

`adb install -r` of the LineageOS WebView fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
(signatures don't match the vendor package). Replacing the files in `/system` bypasses that — the
package keeps its name `com.android.webview`, and on Android 6 the WebView provider is simply the
package named by the framework's `config_webviewPackageName` (no per-signature provider check like
7.0+), so the new files are used after a reboot.

## Verify

Do **not** open the kiosk/browser before rebooting (it crashes in `WebViewFactory` because the
package manager still has WebView 44 registered, and that can clear a Home "Always" choice). After
`adb reboot`:

```sh
adb shell dumpsys package com.android.webview | grep versionName      # 106.0.5249.126
adb logcat -c; adb shell am start -a android.intent.action.VIEW -d about:blank -n com.android.browser/.BrowserActivity
adb logcat -d | grep -iE 'WebViewFactory: Loading|Failed to load library|dlopen'
# want: "Loading com.android.webview version 106.0.5249.126", and NO "Failed to load library"
```

Then load your dashboard in the browser and screenshot — it should render.

## WebView 106 limitations

It's a 2022 engine. It **lacks** `oklch()`, `color-mix()`, CSS nesting and `:has()`. Tailwind v4's
default OKLCH color palette breaks. Build your dashboard for **Chrome 106** (flexbox over brand-new
CSS, no `:has()`-dependent layout).

## Undo

```sh
adb shell su -c 'mount -o remount,rw /system; \
  cp /system/app/webview/webview.apk.bak /system/app/webview/webview.apk; \
  rm -rf /system/app/webview/lib; mount -o remount,ro /system'
adb reboot
```

→ Next: [3. Add Let's Encrypt roots](03-letsencrypt-roots.md)
