#!/bin/bash
# BM1688 USB Gadget auto init: RNDIS + Mass Storage
# Use existing /data/usb_disk.img as backing file. Do NOT recreate or format it here.

set -u

IMG=/data/usb_disk.img
IP_ADDR=192.168.188.138
IP_CIDR=192.168.188.138/24
USB_MODE_PATH=/sys/kernel/debug/usb/39010000.usb/mode
CONFIGFS_GADGET_ROOT=/sys/kernel/config/usb_gadget

log() { echo "[usb_gadget_init] $*"; }
fail() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" = "0" ] || fail "must run as root"

# 1) Check image exists. This script assumes the image is already partitioned/formatted.
[ -f "$IMG" ] || fail "$IMG not found"
[ -s "$IMG" ] || fail "$IMG is empty"


if [ -w "$USB_MODE_PATH" ]; then
  echo device > "$USB_MODE_PATH" 2>/dev/null || true
else
  log "warn: $USB_MODE_PATH not writable, skip OTG mode switch"
fi

# 3) Avoid exporting an image that is still attached/mounted through loop.
# Only detach loop devices that point to this IMG; do not use losetup -D globally.
if command -v losetup >/dev/null 2>&1; then
  losetup -j "$IMG" 2>/dev/null | cut -d: -f1 | while read -r dev; do
    [ -n "$dev" ] || continue
    if command -v findmnt >/dev/null 2>&1; then
      if findmnt -rn -S "$dev" >/dev/null 2>&1 || findmnt -rn -S "${dev}p1" >/dev/null 2>&1; then
        fail "$IMG is mounted through $dev, unmount it before starting USB Mass Storage"
      fi
    fi
    log "detach old loop: $dev"
    losetup -d "$dev" 2>/dev/null || true
  done
fi

# 4) Stop old gadget first. This unbinds UDC so lun.0/file, ro, removable are writable.
run_usb.sh stop 2>/dev/null || true
sleep 1

# Extra unbind guard.
if [ -d "$CONFIGFS_GADGET_ROOT" ]; then
  for udc in "$CONFIGFS_GADGET_ROOT"/*/UDC; do
    [ -e "$udc" ] || continue
    echo "" > "$udc" 2>/dev/null || true
  done
fi

# 5) Create/probe RNDIS + MSC function. Export the whole disk image, not /dev/loopXp1.
run_usb.sh probe rndis || fail "run_usb.sh probe rndis failed"
run_usb.sh probe msc "$IMG" || fail "run_usb.sh probe msc $IMG failed"

# 6) Locate mass_storage LUN in configfs and force sane parameters before start.
G=$(find "$CONFIGFS_GADGET_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)
[ -n "${G:-}" ] || fail "no usb gadget found under $CONFIGFS_GADGET_ROOT"

MSC=$(find "$G/functions" -maxdepth 1 -type d -name 'mass_storage*' 2>/dev/null | head -n1)
[ -n "${MSC:-}" ] || fail "mass_storage function not found under $G/functions"
[ -d "$MSC/lun.0" ] || fail "LUN path not found: $MSC/lun.0"

# Set file while gadget is stopped/unbound. removable=0 avoids '(no medium)' state for fixed disk.
echo ""     > "$MSC/lun.0/file" 2>/dev/null || true
echo 0      > "$MSC/lun.0/removable" || fail "set removable failed"
echo "$IMG" > "$MSC/lun.0/file"      || fail "set LUN file failed"

LUN_FILE=$(cat "$MSC/lun.0/file" 2>/dev/null || true)
[ "$LUN_FILE" = "$IMG" ] || fail "LUN file mismatch: '$LUN_FILE'"

log "G=$G"
log "MSC=$MSC"
log "LUN file=$(cat "$MSC/lun.0/file")"
log "removable=$(cat "$MSC/lun.0/removable") ro=$(cat "$MSC/lun.0/ro")"

# 7) Start gadget.
run_usb.sh start || fail "run_usb.sh start failed"
sleep 1

# 8) Configure usb0 IP. Use ip when available, fallback to ifconfig.
if command -v ip >/dev/null 2>&1; then
  ip link set usb0 up 2>/dev/null || true
  ip addr replace "$IP_CIDR" dev usb0 2>/dev/null || true
else
  ifconfig usb0 "$IP_ADDR" up 2>/dev/null || true
fi

log "done: RNDIS usb0=$IP_ADDR, MSC image=$IMG"
exit 0
