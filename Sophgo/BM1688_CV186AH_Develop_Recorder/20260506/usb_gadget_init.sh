#!/bin/bash
# BM1688 USB Gadget auto init: RNDIS + MSC (export /dev/mmcblk0p6 as U-disk style)

set -u

IP_ADDR=192.168.188.138
IP_CIDR=192.168.188.138/24
USB_MODE_PATH=/sys/kernel/debug/usb/39010000.usb/mode
MSC_DEV=/dev/mmcblk0p6
G=/tmp/usb/usb_gadget/cvitek
MSC_LABEL=BM1688_MSC
MSC_INIT_FLAG=/data/.msc_inited

log() { echo "[usb_gadget_init] $*"; }
fail() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" = "0" ] || fail "must run as root"
command -v run_usb.sh >/dev/null 2>&1 || fail "run_usb.sh not found"

# Switch USB to device mode (ignore if not writable on this platform)
[ -w "$USB_MODE_PATH" ] && echo device > "$USB_MODE_PATH" 2>/dev/null || true

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
  mkfs.vfat -F 32 -n BM1688_MSC "$MSC_DEV" || fail "mkfs.vfat failed on $MSC_DEV"
  sync 
  mkdir -p /data
  touch "$MSC_INIT_FLAG"
  sync
else
  log "MSC already initialized, skip format"
fi
# Restart gadget cleanly
run_usb.sh stop 2>/dev/null || true
sleep 1

# Probe functions
run_usb.sh probe rndis || fail "probe rndis failed"
run_usb.sh probe msc "$MSC_DEV" || fail "probe msc failed"

# Configure all mass_storage LUNs dynamically
for d in "$G"/functions/mass_storage.usb*/lun.0; do
  [ -d "$d" ] || continue
  echo "" > "$d/file" 2>/dev/null || true
  echo 0  > "$d/ro" 2>/dev/null || true
  echo 1  > "$d/removable" 2>/dev/null || true   # U-disk behavior on Windows
  echo 0  > "$d/cdrom" 2>/dev/null || true
  echo "$MSC_DEV" > "$d/file" 2>/dev/null || fail "set LUN file failed: $d"
done

sync
sleep 1
run_usb.sh start || fail "run_usb.sh start failed"
sleep 2

# Bring up RNDIS interface
if command -v ip >/dev/null 2>&1; then
  ip link set usb0 up 2>/dev/null || true
  ip addr replace "$IP_CIDR" dev usb0 2>/dev/null || true
else
  ifconfig usb0 "$IP_ADDR" up 2>/dev/null || true
fi

log "done: MSC=$MSC_DEV, fstype=$(blkid -o value -s TYPE "$MSC_DEV" 2>/dev/null || echo unknown)"
exit 0
