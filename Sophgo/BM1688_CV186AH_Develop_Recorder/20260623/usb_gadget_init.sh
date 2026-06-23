#!/bin/bash
# BM1688 USB Gadget auto init: selectable RNDIS / MSC / ADB functions.

set -u

IP_ADDR=192.168.188.1
IP_CIDR=192.168.188.1/24
USB_MODE_PATH=/sys/kernel/debug/usb/39010000.usb/mode
MSC_DEV=/dev/mmcblk0p6
G=/tmp/usb/usb_gadget/cvitek
ADB_FFS_DIR=/dev/usb-ffs/adb
MSC_LABEL=CLAWSTAR
MSC_INIT_FLAG=/data/.msc_inited
ENABLE_RNDIS=0
ENABLE_MSC=0
ENABLE_ADB=0

log() { echo "[usb_gadget_init] $*"; }
fail() { log "ERROR: $*"; exit 1; }

if [ $# -eq 0 ]; then
  set -- rndis msc
fi

for f in "$@"; do
  case "$f" in
    rndis) ENABLE_RNDIS=1 ;;
    msc) ENABLE_MSC=1 ;;
    adb) ENABLE_ADB=1 ;;
    *) fail "unknown USB function: $f, expected: rndis msc adb" ;;
  esac
done

[ "$ENABLE_RNDIS$ENABLE_MSC$ENABLE_ADB" != "000" ] || fail "no USB functions selected"

[ "$(id -u)" = "0" ] || fail "must run as root"
command -v run_usb.sh >/dev/null 2>&1 || fail "run_usb.sh not found"
if [ "$ENABLE_ADB" = "1" ]; then
  [ -x /usr/sbin/adbd ] || fail "adbd not found or not executable: /usr/sbin/adbd"
fi

# Switch USB to device mode (ignore if not writable on this platform)
[ -w "$USB_MODE_PATH" ] && echo device > "$USB_MODE_PATH" 2>/dev/null || true

if [ "$ENABLE_MSC" = "1" ]; then
  # Wait for MSC block device
  for i in $(seq 1 15); do
    [ -b "$MSC_DEV" ] && break
    sleep 1
  done
  [ -b "$MSC_DEV" ] || fail "MSC dev not found: $MSC_DEV"

  # One-time init with flag:
  # - first boot: if not vfat then format to vfat with label
  # - later boots: never format again
  if [ ! -f "$MSC_INIT_FLAG" ]; then
    FSTYPE="$(blkid -o value -s TYPE "$MSC_DEV" 2>/dev/null || true)"
    mkfs.vfat -F 32 -n "$MSC_LABEL" "$MSC_DEV" || fail "mkfs.vfat failed on $MSC_DEV"
    sync
    mkdir -p /data
    touch "$MSC_INIT_FLAG"
    sync
  else
    log "MSC already initialized, skip format"
  fi
fi

# Restart gadget cleanly
run_usb.sh stop 2>/dev/null || true
sleep 1

# Probe functions. ADB must be probed last.
if [ "$ENABLE_RNDIS" = "1" ]; then
  run_usb.sh probe rndis || fail "probe rndis failed"
fi
if [ "$ENABLE_MSC" = "1" ]; then
  run_usb.sh probe msc "$MSC_DEV" || fail "probe msc failed"
fi
if [ "$ENABLE_ADB" = "1" ]; then
  run_usb.sh probe adb || fail "probe adb failed"
fi

if [ "$ENABLE_MSC" = "1" ]; then
  # Configure all mass_storage LUNs dynamically.
  for d in "$G"/functions/mass_storage.usb*/lun.0; do
    [ -d "$d" ] || continue
    echo "" > "$d/file" 2>/dev/null || true
    echo 0  > "$d/ro" 2>/dev/null || true
    echo 1  > "$d/removable" 2>/dev/null || true   # U-disk behavior on Windows
    echo 0  > "$d/cdrom" 2>/dev/null || true
    echo "$MSC_DEV" > "$d/file" 2>/dev/null || fail "set LUN file failed: $d"
  done
fi

sync
sleep 1
run_usb.sh start || fail "run_usb.sh start failed"

if [ "$ENABLE_ADB" = "1" ]; then
  sleep 2
  # Wait until adbd has written FunctionFS descriptors and endpoints exist.
  for i in $(seq 1 20); do
    [ -e "$ADB_FFS_DIR/ep1" ] && [ -e "$ADB_FFS_DIR/ep2" ] && break
    sleep 0.1
  done
  [ -e "$ADB_FFS_DIR/ep1" ] && [ -e "$ADB_FFS_DIR/ep2" ] || fail "adbd FunctionFS endpoints not ready"

  run_usb.sh UDC || fail "bind UDC failed"
fi

if [ "$ENABLE_RNDIS" = "1" ]; then
  # Bring up RNDIS interface
  if command -v ip >/dev/null 2>&1; then
    ip link set usb0 up 2>/dev/null || true
    ip addr replace "$IP_CIDR" dev usb0 2>/dev/null || true
  else
    ifconfig usb0 "$IP_ADDR" up 2>/dev/null || true
  fi
fi

log "done: rndis=$ENABLE_RNDIS, msc=$ENABLE_MSC, adb=$ENABLE_ADB, MSC=$MSC_DEV, fstype=$(blkid -o value -s TYPE "$MSC_DEV" 2>/dev/null || echo unknown)"
exit 0
