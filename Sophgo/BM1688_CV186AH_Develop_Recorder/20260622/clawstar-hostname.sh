#!/bin/bash

set -e

IFACE="${1:-wlan0}"
PREFIX="${CLAWSTAR_HOSTNAME_PREFIX:-clawstar}"
HOSTS_FILE=/etc/hosts

log() {
	echo "[clawstar-hostname] $*"
}

for _ in $(seq 1 40); do
	if [ -r "/sys/class/net/$IFACE/address" ]; then
		break
	fi
	sleep 1
done

if [ ! -r "/sys/class/net/$IFACE/address" ]; then
	log "ERROR: interface not found: $IFACE"
	exit 1
fi

MAC="$(cat "/sys/class/net/$IFACE/address")"
LAST4="$(echo "$MAC" | awk -F: '{print toupper($(NF-1) $NF)}')"

if ! echo "$LAST4" | grep -Eq '^[0-9A-F]{4}$'; then
	log "ERROR: invalid MAC for $IFACE: $MAC"
	exit 1
fi

NEW_HOSTNAME="$PREFIX-$(echo "$LAST4" | tr 'A-Z' 'a-z')"

log "interface $IFACE MAC: $MAC"
log "hostname: $NEW_HOSTNAME"

hostnamectl set-hostname "$NEW_HOSTNAME"

if grep -qE '^127\.0\.1\.1[[:space:]]+' "$HOSTS_FILE"; then
	sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1	$NEW_HOSTNAME/" "$HOSTS_FILE"
else
	printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> "$HOSTS_FILE"
fi

if command -v systemctl >/dev/null 2>&1; then
	systemctl try-restart avahi-daemon.service >/dev/null 2>&1 || true
fi

log "mDNS name: $NEW_HOSTNAME.local"
