#!/usr/bin/env bash
# Find the frame on the LAN and connect ADB over TCP to it.
#
# These frames sit on DHCP, so the address moves. `adb connect` failing with
# "No route to host" is an ARP-level failure — the frame is not answering at
# all — which almost always means the IP changed, the frame is powered off, or
# it is not on WiFi. It does NOT mean the boot patch (doc 1) regressed.
#
# This sweeps the subnet for anything listening on ADB's TCP port, prints the
# MAC of each hit so you can tell the frame from your other devices, and
# connects. The sweep ARP-probes every address first, so hosts that ignore
# ICMP are still found.
#
# A frame in Rockchip Loader mode is not on the network at all — if nothing is
# found, check `lsusb -d 2207:` before assuming anything is broken (see doc 5).
#
# Requirements: adb, iproute2 (ip), ping.
#
# Usage:  ./find-frame.sh [rounds] [subnet]
#           rounds  how many times to retry, 8s apart (default 1; use ~20 while
#                   the frame is still booting — adbd appears ~50-60s after boot)
#           subnet  first three octets, e.g. 192.168.1 (default: autodetected)
#
#         FRAME_MAC=aa:bb:cc:dd:ee:ff ./find-frame.sh   # label your frame in the output
set -uo pipefail

ROUNDS="${1:-1}"
PORT="${ADB_TCP_PORT:-5555}"
FRAME_MAC="${FRAME_MAC:-}"

# Autodetect the /24 of the interface holding the default route.
if [ "${2:-}" ]; then
  SUBNET="$2"
else
  host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
  [ -n "$host_ip" ] || { echo "could not autodetect your subnet - pass it: $0 $ROUNDS 192.168.1" >&2; exit 2; }
  SUBNET="${host_ip%.*}"
  echo "sweeping ${SUBNET}.0/24 for ADB on port $PORT (override: $0 $ROUNDS <subnet>)"
fi

for round in $(seq 1 "$ROUNDS"); do
  # Populate the ARP cache so ICMP-silent hosts are still discovered.
  for i in $(seq 1 254); do ping -c1 -W1 "$SUBNET.$i" >/dev/null 2>&1 & done
  wait

  hits="$(
    for i in $(seq 1 254); do
      ( timeout 1 bash -c "echo > /dev/tcp/$SUBNET.$i/$PORT" 2>/dev/null && echo "$SUBNET.$i" ) &
    done
    wait
  )"
  hits="$(printf '%s\n' "$hits" | sed '/^$/d' | sort -u)"

  if [ -n "$hits" ]; then
    echo "ADB port $PORT open on:"
    for ip in $hits; do
      mac="$(ip neigh show "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')"
      if [ -n "$FRAME_MAC" ] && [ "$mac" = "$FRAME_MAC" ]; then
        echo "  $ip  (mac $mac)  <- your frame"
      else
        echo "  $ip  (mac ${mac:-unknown})"
      fi
    done
    for ip in $hits; do
      adb connect "$ip:$PORT" >/dev/null 2>&1
      model="$(adb -s "$ip:$PORT" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
      board="$(adb -s "$ip:$PORT" shell getprop ro.board.platform 2>/dev/null | tr -d '\r')"
      [ -n "$model" ] && echo "connected: $ip:$PORT  model=$model board=$board"
    done
    exit 0
  fi

  echo "round $round/$ROUNDS: nothing on port $PORT"
  [ "$round" -lt "$ROUNDS" ] && sleep 8
done

cat >&2 <<'MSG'

Frame not found. Check in this order:

  1. Is it powered on and past boot (dashboard showing)? adbd appears
     ~50-60s after boot - retry with more rounds: ./find-frame.sh 20
  2. lsusb -d 2207:   - if a device is listed the frame is in Loader mode,
     NOT booted, so it is not on the network at all. Boot it with
     `rkdeveloptool rd`. See docs/05-loader-mode-and-recovery.md.
  3. Is it on this subnet? A guest/IoT VLAN or a 2.4GHz-only SSID can put
     the frame on a different network than your computer.
  4. Only then suspect the boot patch - verify it instead of reflashing
     blind: docs/05-loader-mode-and-recovery.md
MSG
exit 1
