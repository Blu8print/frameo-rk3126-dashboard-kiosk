#!/usr/bin/env bash
# Replace the stock system WebView (Chromium 44.0.2403.119) with WebView 106.0.5249.126 on a
# Frameo RK3126 / Android 6.0.1 frame. 106 is the newest WebView that runs on Android 6 (API 23).
#
# Requirements: adb, curl, unzip, openssl (or sha256sum/shasum); the frame rooted (shipped `su`),
# SELinux permissive, and /system a plain ext4 mount (no dm-verity). BACK UP /system FIRST.
#
# Usage:  ./webview-44-to-106.sh [adb-serial]
#         ADB_SERIAL=192.168.x.x:5555 ./webview-44-to-106.sh
set -euo pipefail

ADB_SERIAL="${1:-${ADB_SERIAL:-}}"
adbx() { if [ -n "$ADB_SERIAL" ]; then adb -s "$ADB_SERIAL" "$@"; else adb "$@"; fi; }

WEBVIEW_URL="https://raw.githubusercontent.com/LineageOS/android_external_chromium-webview_prebuilt_arm/4b0ae494a7dd/webview.apk"
WEBVIEW_SHA256="e2edc1f89ec1608b169da9e7ffc037190b70c7825f0be29694f4cae719980580"
WEBVIEW_VERSION="106.0.5249.126"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
echo "Downloading WebView $WEBVIEW_VERSION ..."
curl -sfL -o "$work/webview.apk" "$WEBVIEW_URL"
got="$(sha256 "$work/webview.apk")"
[ "$got" = "$WEBVIEW_SHA256" ] || { echo "SHA-256 mismatch: $got"; exit 1; }
echo "SHA-256 OK."

# WebView 106 ships its native libs compressed; Android 6 will NOT extract them for a /system app,
# so they must be placed, extracted, in lib/arm/ alongside the APK, or it loads version 106 but
# fails at runtime (dlopen). Extract them here.
mkdir -p "$work/wvlib"
unzip -q -j "$work/webview.apk" 'lib/armeabi-v7a/*' -d "$work/wvlib"
echo "Native libs: $(ls "$work/wvlib" | tr '\n' ' ')"

echo "Confirming the frame ..."
plat="$(adbx shell getprop ro.board.platform | tr -d '\r')"
[ "$plat" = "rk312x" ] || { echo "ro.board.platform is '$plat', expected rk312x. Stop."; exit 1; }
adbx shell su -c id | grep -q 'uid=0' || { echo "No root via su. Stop."; exit 1; }

echo "Staging to /data/local/tmp ..."
adbx shell 'rm -rf /data/local/tmp/wvlib; mkdir -p /data/local/tmp/wvlib'
adbx push "$work/webview.apk" /data/local/tmp/webview.apk >/dev/null
adbx push "$work/wvlib/." /data/local/tmp/wvlib/ >/dev/null

# Device-side swap. Retries each write to beat SuperSU's daemonsu, which re-mounts /system
# read-only several times a minute (so `mount -o remount,rw` can flip back between two commands).
cat > "$work/swap.sh" <<'EOS'
W=/system/app/webview; DEV=/data/local/tmp
md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
rw() { n=0; while [ $n -lt 80 ]; do n=$((n+1)); mount -o remount,rw /system 2>/dev/null; if ( echo x > /system/.rwprobe ) 2>/dev/null; then rm -f /system/.rwprobe; return 0; fi; done; echo RW_FAIL; return 1; }
copyv() { k=0; want=$(md5 "$1"); while [ $k -lt 8 ]; do k=$((k+1)); rw || return 1; cp "$1" "$2" 2>/dev/null; [ "$(md5 "$2")" = "$want" ] && return 0; done; echo "FAILED copy $2"; return 1; }
rw || exit 1
[ -f $W/webview.apk.bak ] || cp $W/webview.apk $W/webview.apk.bak   # keep stock 44 for undo
copyv $DEV/webview.apk $W/webview.apk || exit 1
rw; rm -rf $W/oat; mkdir -p $W/lib/arm
for so in $DEV/wvlib/*.so; do copyv "$so" "$W/lib/arm/$(basename "$so")" || exit 1; done
rw; chmod 0644 $W/webview.apk $W/lib/arm/*.so; chmod 0755 $W/lib $W/lib/arm; chown -R 0:0 $W/webview.apk $W/lib
sync; mount -o remount,ro /system
echo SWAP_OK; ls -l $W/lib/arm
EOS
adbx push "$work/swap.sh" /data/local/tmp/swap.sh >/dev/null
echo "Swapping (this writes to /system) ..."
adbx shell su -c 'sh /data/local/tmp/swap.sh'
adbx shell 'rm -rf /data/local/tmp/webview.apk /data/local/tmp/wvlib /data/local/tmp/swap.sh'

cat <<EOF

Done staging. Now REBOOT the frame BEFORE opening any WebView:
    adb reboot
Opening the kiosk/browser before the reboot crashes in WebViewFactory (package manager still has
WebView 44 registered) and can clear a Home "Always" choice.

After reboot, verify:
    adb shell dumpsys package com.android.webview | grep versionName    # $WEBVIEW_VERSION
    adb logcat -d | grep -i 'Failed to load library'                    # (should be empty)

Undo: mount -o remount,rw /system; cp /system/app/webview/webview.apk.bak /system/app/webview/webview.apk; \\
      rm -rf /system/app/webview/lib; mount -o remount,ro /system; reboot
EOF
