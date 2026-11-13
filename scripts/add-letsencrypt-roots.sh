#!/usr/bin/env bash
# Add the Let's Encrypt ISRG Root X1 and X2 CA certificates to the Android 6 system trust store.
# Android 6's store predates them, so WebView rejects sites that chain to Let's Encrypt with
# "Certificate error 3" (SSL_UNTRUSTED) — e.g. anything on *.pages.dev / many self-hosted sites.
#
# Requirements: adb, curl, openssl; the frame rooted; /system writable (plain ext4, no dm-verity).
#
# Usage:  ./add-letsencrypt-roots.sh [adb-serial]
set -euo pipefail

ADB_SERIAL="${1:-${ADB_SERIAL:-}}"
adbx() { if [ -n "$ADB_SERIAL" ]; then adb -s "$ADB_SERIAL" "$@"; else adb "$@"; fi; }

X1_URL="https://letsencrypt.org/certs/isrgrootx1.pem"
X1_FP="96:BC:EC:06:26:49:76:F3:74:60:77:9A:CF:28:C5:A7:CF:E8:A3:C0:AA:E1:1A:8F:FC:EE:05:C0:BD:DF:08:C6"
X2_URL="https://letsencrypt.org/certs/isrg-root-x2.pem"
X2_FP="69:72:9B:8E:15:A8:6E:FC:17:7A:57:AF:B7:17:1D:FC:64:AD:D2:8C:2F:CA:8C:F1:50:7E:34:45:3C:CB:14:70"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
names=""
for pair in "$X1_URL $X1_FP" "$X2_URL $X2_FP"; do
  set -- $pair; url=$1; fp=$2
  pem="$work/$(basename "$url")"
  curl -sfL -o "$pem" "$url"
  got="$(openssl x509 -in "$pem" -noout -fingerprint -sha256 | cut -d= -f2)"
  [ "$got" = "$fp" ] || { echo "Fingerprint mismatch for $url"; exit 1; }
  # Android cacert filename is the old-style subject hash + .0; contents = PEM + human text dump.
  h="$(openssl x509 -in "$pem" -noout -subject_hash_old)"
  { openssl x509 -in "$pem" -outform PEM; openssl x509 -in "$pem" -noout -text -fingerprint; } > "$work/$h.0"
  adbx push "$work/$h.0" "/data/local/tmp/$h.0" >/dev/null
  names="$names $h.0"
  echo "Prepared $h.0  ($(openssl x509 -in "$pem" -noout -subject | sed 's/.*CN *= *//'))"
done

cat > "$work/install.sh" <<EOS
rw() { n=0; while [ \$n -lt 80 ]; do n=\$((n+1)); mount -o remount,rw /system 2>/dev/null; if ( echo x > /system/.rwprobe ) 2>/dev/null; then rm -f /system/.rwprobe; return 0; fi; done; echo RW_FAIL; return 1; }
for f in$names; do
  want=\$(md5sum /data/local/tmp/\$f | cut -d' ' -f1); k=0
  while [ \$k -lt 12 ]; do k=\$((k+1)); rw || exit 1; cp /data/local/tmp/\$f /system/etc/security/cacerts/\$f 2>/dev/null
    [ "\$(md5sum /system/etc/security/cacerts/\$f 2>/dev/null | cut -d' ' -f1)" = "\$want" ] && break; done
  rw; chmod 0644 /system/etc/security/cacerts/\$f; chown 0:0 /system/etc/security/cacerts/\$f
done
sync; mount -o remount,ro /system; echo CERTS_DONE; ls -l /system/etc/security/cacerts/*.0 | tail -4
EOS
adbx push "$work/install.sh" /data/local/tmp/install.sh >/dev/null
echo "Installing into /system/etc/security/cacerts ..."
adbx shell su -c 'sh /data/local/tmp/install.sh'
adbx shell "rm -f /data/local/tmp/install.sh$(for f in $names; do echo -n " /data/local/tmp/$f"; done)"
echo "Done. Restart the kiosk (or reboot) so WebView re-reads the trust store."
echo "Undo: rm /system/etc/security/cacerts/<hash>.0 for each added file (remount rw first)."
