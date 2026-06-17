#!/bin/bash 

### BEGIN INIT INFO
# Provides:          quectel-setup
# Required-Start:    $local_fs $network
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Setup Quectel 4/5G module
# Description:       Send AT commands to initialize Quectel 4/5G module
### END INIT INFO

DEVICE="/dev/ttyUSB2"
BAUDRATE=115200
TIMEOUT=30
NCM_TIMEOUT=480
NCM_IFACE_TIMEOUT="${NCM_IFACE_TIMEOUT:-180}"
DHCP_TIMEOUT=30
ENABLE_AT_SETUP="${ENABLE_AT_SETUP:-0}"

FALLBACK_DNS="${FALLBACK_DNS:-114.114.114.114 223.5.5.5}"

log() {
    echo "$(date): $1" >> /var/log/quectel-setup.log
}

start_quectel_cm() {
    if ! command -v quectel-CM >/dev/null 2>&1; then
        log "WARNING: quectel-CM not found"
        return 1
    fi

    if pidof quectel-CM >/dev/null 2>&1; then
        log "quectel-CM is already running"
        return 0
    fi

    log "Starting quectel-CM"
    nohup quectel-CM >> /var/log/quectel-autoconnect.log 2>&1 &
    sleep 2
    
    if ! pidof quectel-CM >/dev/null 2>&1; then
        log "WARNING: quectel-CM exited shortly after start"
        return 1
    fi

    return 0
}

wait_for_device() {
    log "Waiting for device $DEVICE to be ready..."
    local counter=0

    if [ -e "$DEVICE" ] && [ ! -c "$DEVICE" ]; then
        log "WARNING: Removing stale non-character device node $DEVICE"
        rm -f "$DEVICE"
    fi

    log "Waiting for Quectel NCM interface to be ready..."

    while [ -z "$(find_ncm_ifaces)" ] && [ "$counter" -lt "$NCM_IFACE_TIMEOUT" ]; do
        sleep 1
        counter=$((counter+1))
    done

    if [ ! -c "$DEVICE" ]; then
        log "WARNING: Device $DEVICE not found after ${TIMEOUT} seconds, skip AT setup"
        return 1
    fi

    log "Device $DEVICE is ready"
    return 0
}

setup_module() { 
    log "Setting up Quectel module..."

    if [ ! -c "$DEVICE" ]; then
        log "ERROR: $DEVICE is not a character device, skip module setup"
        return 1
    fi

    stty -F "$DEVICE" "$BAUDRATE" raw -echo -echoe -echok 2>/dev/null || \
        log "WARNING: Failed to configure serial baudrate for $DEVICE"

    exec 3<> $DEVICE

    echo -e "AT\r" >&3
    sleep 1

    echo -e "AT+CPIN?\r" >&3
    sleep 1
    
    echo -e "AT+CSQ\r" >&3
    sleep 1
    
    echo -e "AT+COPS?\r" >&3
    sleep 1
    
    exec 3<&-
    exec 3>&-
    
    log "Quectel module setup completed"
}

get_iface_ipv4() {
    local iface=$1

    ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR == 1 {print $4}'
}

has_default_route() {
    local iface=$1

    ip route show default dev "$iface" 2>/dev/null | grep -q '^default '
}

has_dns() {
    grep -Eq '^[[:space:]]*nameserver[[:space:]]+[^[:space:]]+' /etc/resolv.conf 2>/dev/null
}

install_fallback_route() {
    local iface=$1
    local cidr
    local ipaddr
    local gateway

    has_default_route "$iface" && return 0

    cidr=$(get_iface_ipv4 "$iface")
    [ -n "$cidr" ] || return 1

    ipaddr=${cidr%/*}
    gateway=${ipaddr%.*}.1

    log "No default route for $iface, fallback to gateway $gateway"
    ip route replace default via "$gateway" dev "$iface" || {
        log "WARNING: Failed to install fallback default route via $gateway dev $iface"
        return 1
    }
}

install_fallback_dns() {
    local ns

    has_dns && return 0

    log "No DNS server in /etc/resolv.conf, installing fallback DNS"
    : > /etc/resolv.conf || {
        log "WARNING: Failed to write /etc/resolv.conf"
        return 1
    }

    for ns in $FALLBACK_DNS; do
        echo "nameserver $ns" >> /etc/resolv.conf
    done
}

wait_for_ipv4() {
    local iface=$1
    local counter=0

    while [ -z "$(get_iface_ipv4 "$iface")" ] && [ "$counter" -lt "$DHCP_TIMEOUT" ]; do
        sleep 1
        counter=$((counter+1))
    done

    [ -n "$(get_iface_ipv4 "$iface")" ]
}

run_dhcp() {
    local iface=$1
	local udhcpc_script=""

    if command -v networkctl >/dev/null 2>&1; then
        networkctl reconfigure "$iface" >/dev/null 2>&1 || true
    fi

    if command -v dhclient >/dev/null 2>&1; then
        log "Requesting DHCP lease on $iface with dhclient"
        dhclient -1 -q "$iface" >/dev/null 2>&1 || \
            log "WARNING: dhclient failed on $iface"
    elif command -v udhcpc >/dev/null 2>&1; then
        if [ -x /usr/share/udhcpc/default.script ]; then
            udhcpc_script="/usr/share/udhcpc/default.script"
        elif [ -x /etc/udhcpc/default.script ]; then
            udhcpc_script="/etc/udhcpc/default.script"
        fi

        log "Requesting DHCP lease on $iface with udhcpc"
        if [ -n "$udhcpc_script" ]; then
            udhcpc -f -n -q -t 5 -i "$iface" -s "$udhcpc_script" >/dev/null 2>&1 || \
                log "WARNING: udhcpc failed on $iface"
        else
            udhcpc -f -n -q -t 5 -i "$iface" >/dev/null 2>&1 || \
                log "WARNING: udhcpc failed on $iface"
        fi
    else
        log "WARNING: No DHCP client found"
    fi

    wait_for_ipv4 "$iface" || log "WARNING: $iface has no IPv4 address after DHCP"
    install_fallback_route "$iface" || true
    install_fallback_dns || true
}

find_ncm_ifaces() {
    local iface
    local driver

    for iface in /sys/class/net/*; do
        iface=${iface##*/}
        [ "$iface" = "lo" ] && continue
        [ -e "/sys/class/net/$iface/device/driver" ] || continue

        driver=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver")")
        [ "$driver" = "cdc_ncm" ] && echo "$iface"
    done
}

wait_for_carrier() {
    local iface=$1
    local counter=0

    if [ ! -r "/sys/class/net/$iface/carrier" ]; then
        log "WARNING: Cannot read carrier state for $iface"
        return 1
    fi

    while [ "$(cat "/sys/class/net/$iface/carrier")" = "0" ] && [ $counter -lt $NCM_TIMEOUT ]; do
        sleep 1
        counter=$((counter+1))
    done

    if [ "$(cat "/sys/class/net/$iface/carrier")" = "0" ]; then
        log "WARNING: $iface has no carrier after ${NCM_TIMEOUT} seconds"
        return 1
    fi

    log "$iface carrier is ready"
    return 0
}

wait_for_ncm_iface() {
    local counter=0

    while [ -z "$(find_ncm_ifaces)" ] && [ "$counter" -lt "$TIMEOUT" ]; do
        sleep 1
        counter=$((counter+1))
    done

    if [ -z "$(find_ncm_ifaces)" ]; then
        log "WARNING: No cdc_ncm network interface found after ${NCM_IFACE_TIMEOUT} seconds"
        return 1
    fi

    log "Quectel NCM interface is ready: $(find_ncm_ifaces)"
    return 0
}

setup_network() {
    local iface
    local found=0

    for iface in $(find_ncm_ifaces); do
        found=1
        log "Bringing up Quectel NCM interface $iface"
        ip link set "$iface" up || {
            log "ERROR: Failed to bring up $iface"
            continue
        }

        if wait_for_carrier "$iface"; then
            run_dhcp "$iface"
        fi
    done

    if [ "$found" -eq 0 ]; then
        log "WARNING: No cdc_ncm network interface found"
        return 1
    fi

    return 0
}

connect_quectel() {
    wait_for_device || return 1
    wait_for_ncm_iface || return 1
    start_quectel_cm || return 1
    setup_network
}


case "$1" in
    start)
        if [ "$ENABLE_AT_SETUP" = "1" ]; then
            wait_for_device && setup_module
        else
            log "Skip AT setup by default; set ENABLE_AT_SETUP=1 to enable it"
        fi
        connect_quectel
        ;;
    stop)
        log "Quectel module setup script stopped"
        ;;
    restart|reload)
        if [ "$ENABLE_AT_SETUP" = "1" ]; then
            wait_for_device && setup_module
        else
            log "Skip AT setup by default; set ENABLE_AT_SETUP=1 to enable it"
        fi
        connect_quectel
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
esac

exit 0
