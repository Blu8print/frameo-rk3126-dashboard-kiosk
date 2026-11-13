# 3. Add Let's Encrypt (ISRG) roots

## Why

Android 6's CA trust store predates **Let's Encrypt**. Sites whose certificate chains to **ISRG
Root X1 / X2** (that includes anything on `*.pages.dev` and a lot of self-hosted HTTPS) fail to
validate, and WebView reports:

```
Certificate error 3    (SSL_UNTRUSTED)
```

The kiosk, by design, **never bypasses certificate errors** — so instead of a warning you get its
"Can't reach the dashboard" screen on an endless retry. The fix is to trust the roots, not to
bypass validation.

> Check what your site actually chains to:
> ```sh
> echo | openssl s_client -connect your-host:443 -servername your-host -showcerts 2>/dev/null \
>   | grep -E '^ *i:'
> ```
> If you see `O=Let's Encrypt` / `ISRG Root X1`/`X2`, this step is what you need. Sites that chain
> to older roots (e.g. GlobalSign, which Android 6 already trusts via cross-signing) don't need it.

## Do it

```sh
scripts/add-letsencrypt-roots.sh [adb-serial]
# then restart the kiosk (or reboot) so WebView re-reads the trust store
adb shell am force-stop com.wesbos.homehq
adb shell am start -n com.wesbos.homehq/.MainActivity
```

The script downloads ISRG Root X1 and X2 from `letsencrypt.org/certs/`, verifies their SHA-256
fingerprints, writes them into `/system/etc/security/cacerts/` in Android's format (filename =
old-style subject hash + `.0`; contents = PEM plus the human-readable text dump), mode `0644`,
owner `root`. On this frame they land as `6187b673.0` (X1) and `8794b4e3.0` (X2). It retries each
write to beat the daemonsu remount race.

## Verify

```sh
adb shell ls -l /system/etc/security/cacerts/6187b673.0 /system/etc/security/cacerts/8794b4e3.0
adb logcat -d | grep -i 'Certificate error'      # should no longer appear for your site
```

## Undo

```sh
adb shell su -c 'mount -o remount,rw /system; \
  rm /system/etc/security/cacerts/6187b673.0 /system/etc/security/cacerts/8794b4e3.0; \
  mount -o remount,ro /system'
```

→ Next: [4. Build, install & configure the kiosk](04-kiosk-and-launcher.md)
