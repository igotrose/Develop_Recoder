#!/bin/bash

AT_DEVICE="${QUECTEL_4G_AT_DEVICE:-}"
NET_IFACE_REQUEST="${QUECTEL_4G_NET_IFACE:-auto}"
NET_IFACE="$NET_IFACE_REQUEST"
WDM_DEVICE="${QUECTEL_4G_WDM_DEVICE:-/dev/cdc-wdm0}"
QNETDEVCTL="${QUECTEL_4G_QNETDEVCTL:-auto}"
BAUDRATE="${QUECTEL_4G_BAUDRATE:-115200}"
AT_PROBE_TIMEOUT="${QUECTEL_4G_AT_PROBE_TIMEOUT:-3}"
DEVICE_TIMEOUT="${QUECTEL_4G_DEVICE_TIMEOUT:-30}"
MONITOR_INTERVAL="${QUECTEL_4G_MONITOR_INTERVAL:-10}"
NET_START_GRACE="${QUECTEL_4G_NET_START_GRACE:-5}"
DHCP_TIMEOUT="${QUECTEL_4G_DHCP_TIMEOUT:-30}"
MAX_RETRY_INTERVAL="${QUECTEL_4G_MAX_RETRY_INTERVAL:-60}"
QMI_STATE_FILE="${QUECTEL_4G_QMI_STATE_FILE:-/run/quectel-4g-qmi.state}"
FALLBACK_DNS="${QUECTEL_4G_FALLBACK_DNS:-114.114.114.114 223.5.5.5}"
LOG_FILE="${QUECTEL_4G_LOG_FILE:-/var/log/quectel-4g-autoconnect.log}"

log() {
    echo "$(date): $1" >> "$LOG_FILE"
}

find_cmd() {
    local name=$1
    local path

    path=$(command -v "$name" 2>/dev/null) && {
        echo "$path"
        return 0
    }

    for path in /usr/sbin/"$name" /sbin/"$name" /usr/bin/"$name" /bin/"$name"; do
        [ -x "$path" ] && echo "$path" && return 0
    done

    return 1
}

usb_id_present() {
    local vid=$1
    local pid=$2
    local dev

    for dev in /sys/bus/usb/devices/*; do
        [ -r "$dev/idVendor" ] || continue
        [ -r "$dev/idProduct" ] || continue
        [ "$(cat "$dev/idVendor")" = "$vid" ] || continue
        [ "$(cat "$dev/idProduct")" = "$pid" ] || continue
        return 0
    done

    return 1
}

is_4g_module() {
    usb_id_present 2c7c 0125 || \
        usb_id_present 2c7c 0121 || \
        usb_id_present 2c7c 6005 || \
        usb_id_present 05c6 9215
}

compact_text() {
    tr '\r\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

send_at() {
    local port=$1
    local command=$2
    local timeout=${3:-5}
    local output=""
    local line
    local end

    [ -c "$port" ] || return 1

    stty -F "$port" "$BAUDRATE" raw -echo -echoe -echok -ixon -ixoff -crtscts 2>/dev/null || \
        stty -F "$port" "$BAUDRATE" raw -echo -echoe -echok 2>/dev/null || true

    exec 3<>"$port" || return 1
    printf '%s\r' "$command" >&3
    end=$((SECONDS + timeout))

    while [ "$SECONDS" -lt "$end" ]; do
        if IFS= read -r -t 1 line <&3; then
            output="${output}${line}"$'\n'
            case "$line" in
                *OK*|*ERROR*)
                    break
                    ;;
            esac
        fi
    done

    exec 3<&-
    exec 3>&-

    printf '%s' "$output"
}

log_at() {
    local command=$1
    local timeout=${2:-5}
    local response

    [ -c "$AT_DEVICE" ] || return 1

    response=$(send_at "$AT_DEVICE" "$command" "$timeout" 2>/dev/null) || {
        log "WARNING: AT command failed on $AT_DEVICE: $command"
        return 1
    }

    log "$command response: $(printf '%s' "$response" | compact_text)"
}

find_at_port() {
    local port
    local response

    if [ -n "$AT_DEVICE" ]; then
        [ -c "$AT_DEVICE" ] && echo "$AT_DEVICE" && return 0
        return 1
    fi

    while IFS= read -r port; do
        response=$(send_at "$port" AT "$AT_PROBE_TIMEOUT" 2>/dev/null) || {
            log "AT probe failed on $port"
            continue
        }
        if echo "$response" | grep -q OK; then
            echo "$port"
            return 0
        fi

        log "AT probe no OK on $port: $(printf '%s' "$response" | compact_text)"
    done <<EOF
$(at_port_candidates)
EOF

    return 1
}

at_port_candidates() {
    local port
    local real_port
    local seen=""

    for port in /dev/serial/by-id/*Quectel* \
        /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB3 /dev/ttyUSB0 \
        /dev/ttyACM2 /dev/ttyACM1 /dev/ttyACM3 /dev/ttyACM0; do
        [ -e "$port" ] || continue
        real_port=$(readlink -f "$port")
        [ -c "$real_port" ] || continue

        case " $seen " in
            *" $real_port "*)
                continue
                ;;
        esac

        seen="$seen $real_port"
        echo "$real_port"
    done
}

setup_module_at() {
    local apn=${QUECTEL_4G_APN:-}
    local port

    port=$(find_at_port) || {
        log "WARNING: No responsive AT port found"
        return 1
    }

    AT_DEVICE="$port"

    log "Checking 4G module by AT on $AT_DEVICE"
    log_at AT 3 || return 1
    log_at "AT+CPIN?" 5 || true
    log_at "AT+CSQ" 5 || true
    log_at "AT+COPS?" 5 || true
    log_at "AT+CGATT?" 5 || true

    if [ -n "$apn" ]; then
        log "Configuring PDP context by APN: $apn"
        log_at "AT+CGDCONT=1,\"IP\",\"$apn\"" 5 || true
    else
        log "Using module default APN/PDP context"
    fi
}

get_iface_driver() {
    local iface=$1
    local driver_path

    driver_path=$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null) || return 1
    echo "${driver_path##*/}"
}

usb_id_supported() {
    local vid=$1
    local pid=$2

    case "$vid:$pid" in
        2c7c:0125|2c7c:0121|2c7c:6005|05c6:9215)
            return 0
            ;;
    esac

    return 1
}

sysfs_path_has_supported_usb_id() {
    local path
    local vid
    local pid

    path=$(readlink -f "$1" 2>/dev/null) || return 1

    while [ -n "$path" ] && [ "$path" != "/" ]; do
        if [ -r "$path/idVendor" ] && [ -r "$path/idProduct" ]; then
            vid=$(cat "$path/idVendor")
            pid=$(cat "$path/idProduct")
            usb_id_supported "$vid" "$pid" && return 0
        fi

        path=${path%/*}
    done

    return 1
}

iface_is_4g_module_net() {
    local iface=$1

    sysfs_path_has_supported_usb_id "/sys/class/net/$iface/device"
}

net_iface_auto_requested() {
    [ -z "$NET_IFACE_REQUEST" ] || [ "$NET_IFACE_REQUEST" = "auto" ]
}

detect_net_iface() {
    local iface
    local driver

    if ! net_iface_auto_requested; then
        if [ -d "/sys/class/net/$NET_IFACE_REQUEST" ]; then
            NET_IFACE="$NET_IFACE_REQUEST"
            return 0
        fi

        log "Configured 4G network interface is missing: $NET_IFACE_REQUEST, trying auto-detect"
    fi

    for iface in /sys/class/net/wwan* /sys/class/net/wwx* /sys/class/net/usb* /sys/class/net/enx*; do
        [ -d "$iface" ] || continue
        iface=${iface##*/}
        driver=$(get_iface_driver "$iface" 2>/dev/null || echo unknown)

        case "$driver" in
            qmi_wwan|cdc_ether|rndis_host|cdc_ncm|cdc_mbim)
                iface_is_4g_module_net "$iface" || continue
                NET_IFACE="$iface"
                log "Auto-selected 4G network interface: $NET_IFACE, driver=$driver"
                return 0
                ;;
        esac
    done

    return 1
}

wait_for_wwan_ready() {
    local counter=0

    while [ "$counter" -lt "$DEVICE_TIMEOUT" ]; do
        if is_4g_module && detect_net_iface; then
            log "4G WWAN interface ready: $NET_IFACE, driver=$(get_iface_driver "$NET_IFACE" 2>/dev/null || echo unknown)"
            return 0
        fi

        sleep 1
        counter=$((counter + 1))
    done

    log "ERROR: 4G module or WWAN interface not ready, iface=$NET_IFACE"
    return 1
}

get_iface_ipv4() {
    local iface=$1

    ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR == 1 {print $4}'
}

wwan_is_connected() {
    [ -d "/sys/class/net/$NET_IFACE" ] || return 1
    [ -n "$(get_iface_ipv4 "$NET_IFACE")" ]
}

has_default_route() {
    ip route show default 2>/dev/null | grep -q '^default '
}

install_default_route() {
    has_default_route && return 0

    log "No default route found, installing default dev $NET_IFACE"
    ip route replace default dev "$NET_IFACE" metric 50 || {
        log "WARNING: Failed to install default route dev $NET_IFACE"
        return 1
    }
}

has_external_dns() {
    awk '
        /^[[:space:]]*nameserver[[:space:]]+/ {
            if ($2 !~ /^127\./ && $2 != "::1") found = 1
        }
        END { exit found ? 0 : 1 }
    ' /etc/resolv.conf 2>/dev/null
}

install_fallback_dns() {
    local ns

    if command -v resolvectl >/dev/null 2>&1; then
        log "Installing DNS on $NET_IFACE with resolvectl: $FALLBACK_DNS"
        resolvectl dns "$NET_IFACE" $FALLBACK_DNS >/dev/null 2>&1 || \
            log "WARNING: resolvectl dns failed on $NET_IFACE"
        resolvectl domain "$NET_IFACE" "~." >/dev/null 2>&1 || true
        resolvectl default-route "$NET_IFACE" yes >/dev/null 2>&1 || true
        return 0
    fi

    has_external_dns && return 0

    log "No external DNS server found, writing fallback DNS"
    : > /etc/resolv.conf || {
        log "WARNING: Failed to write /etc/resolv.conf"
        return 1
    }

    for ns in $FALLBACK_DNS; do
        echo "nameserver $ns" >> /etc/resolv.conf
    done
}

ensure_network_defaults() {
    install_default_route || true
    install_fallback_dns || true
}

wait_for_ipv4() {
    local counter=0

    while ! wwan_is_connected && [ "$counter" -lt "$DHCP_TIMEOUT" ]; do
        sleep 1
        counter=$((counter + 1))
    done

    wwan_is_connected
}

run_dhcp() {
    local udhcpc_script=""

    if command -v networkctl >/dev/null 2>&1; then
        networkctl reconfigure "$NET_IFACE" >/dev/null 2>&1 || true
    fi

    if command -v dhclient >/dev/null 2>&1; then
        log "Requesting DHCP lease on $NET_IFACE with dhclient"
        dhclient -1 -q "$NET_IFACE" >/dev/null 2>&1 || \
            log "WARNING: dhclient failed on $NET_IFACE"
    elif command -v udhcpc >/dev/null 2>&1; then
        if [ -x /usr/share/udhcpc/default.script ]; then
            udhcpc_script="/usr/share/udhcpc/default.script"
        elif [ -x /etc/udhcpc/default.script ]; then
            udhcpc_script="/etc/udhcpc/default.script"
        fi

        log "Requesting DHCP lease on $NET_IFACE with udhcpc"
        if [ -n "$udhcpc_script" ]; then
            udhcpc -f -n -q -t 5 -i "$NET_IFACE" -s "$udhcpc_script" >/dev/null 2>&1 || \
                log "WARNING: udhcpc failed on $NET_IFACE"
        else
            udhcpc -f -n -q -t 5 -i "$NET_IFACE" >/dev/null 2>&1 || \
                log "WARNING: udhcpc failed on $NET_IFACE"
        fi
    else
        log "WARNING: No DHCP client found"
    fi

    wait_for_ipv4 || {
        log "WARNING: $NET_IFACE has no IPv4 address after DHCP"
        return 1
    }

    log "$NET_IFACE IPv4 is ready: $(get_iface_ipv4 "$NET_IFACE")"
    ensure_network_defaults
}

set_qmi_raw_ip() {
    local raw_ip="/sys/class/net/$NET_IFACE/qmi/raw_ip"

    [ -w "$raw_ip" ] || return 0

    ip link set "$NET_IFACE" down >/dev/null 2>&1 || true
    if echo Y > "$raw_ip" 2>/dev/null; then
        log "Enabled QMI raw_ip on $NET_IFACE"
    else
        log "WARNING: Failed to enable QMI raw_ip on $NET_IFACE"
    fi
}

start_quectel_cm() {
    local cm_bin
    local apn=${QUECTEL_4G_APN:-}

    cm_bin=$(find_cmd quectel-CM) || return 1

    if pidof quectel-CM >/dev/null 2>&1; then
        log "quectel-CM is already running"
        return 0
    fi

    if [ -n "$apn" ]; then
        log "Starting quectel-CM on $NET_IFACE with APN: $apn"
        nohup "$cm_bin" -i "$NET_IFACE" -s "$apn" >> "$LOG_FILE" 2>&1 &
    else
        log "Starting quectel-CM on $NET_IFACE with module default APN"
        nohup "$cm_bin" -i "$NET_IFACE" >> "$LOG_FILE" 2>&1 &
    fi

    sleep "$NET_START_GRACE"

    if ! pidof quectel-CM >/dev/null 2>&1; then
        log "WARNING: quectel-CM exited shortly after start"
        return 1
    fi
}

start_qmicli() {
    local qmicli_bin
    local apn=${QUECTEL_4G_APN:-}
    local request
    local output
    local cid
    local pdh

    qmicli_bin=$(find_cmd qmicli) || return 1
    [ -c "$WDM_DEVICE" ] || {
        log "WARNING: qmicli found but WDM device is missing: $WDM_DEVICE"
        return 1
    }

    "$qmicli_bin" -d "$WDM_DEVICE" --device-open-proxy --wda-set-data-format=raw-ip >/dev/null 2>&1 || true

    if [ -n "$apn" ]; then
        request="apn='$apn',ip-type=4"
        log "Starting QMI network with qmicli, APN=$apn"
    else
        request="ip-type=4"
        log "Starting QMI network with qmicli, module default APN"
    fi

    output=$("$qmicli_bin" -d "$WDM_DEVICE" --device-open-proxy \
        --wds-start-network="$request" --client-no-release-cid 2>&1) || {
        log "WARNING: qmicli start network failed: $(printf '%s' "$output" | compact_text)"
        return 1
    }

    cid=$(printf '%s\n' "$output" | sed -n "s/.*CID: '\\([0-9][0-9]*\\)'.*/\\1/p" | tail -n 1)
    pdh=$(printf '%s\n' "$output" | sed -n "s/.*Packet data handle: '\\([0-9][0-9]*\\)'.*/\\1/p" | tail -n 1)

    if [ -n "$cid" ] && [ -n "$pdh" ]; then
        mkdir -p "${QMI_STATE_FILE%/*}" 2>/dev/null || true
        {
            echo "CID=$cid"
            echo "PDH=$pdh"
        } > "$QMI_STATE_FILE"
        log "qmicli network started, cid=$cid pdh=$pdh"
    else
        log "qmicli network started: $(printf '%s' "$output" | compact_text)"
    fi
}

start_qmi_session() {
    local driver

    driver=$(get_iface_driver "$NET_IFACE" 2>/dev/null || echo unknown)
    [ "$driver" = "qmi_wwan" ] || return 0

    set_qmi_raw_ip
    ip link set "$NET_IFACE" up >/dev/null 2>&1 || true

    if start_quectel_cm; then
        return 0
    fi

    if start_qmicli; then
        return 0
    fi

    log "ERROR: qmi_wwan requires quectel-CM or qmicli/libqmi-utils to start data session"
    return 1
}

qnetdevctl_enabled() {
    local driver=$1

    case "$QNETDEVCTL" in
        1|yes|true|on)
            return 0
            ;;
        0|no|false|off)
            return 1
            ;;
        auto|"")
            case "$driver" in
                cdc_ether|rndis_host)
                    return 0
                    ;;
            esac
            ;;
        *)
            log "WARNING: Invalid QUECTEL_4G_QNETDEVCTL=$QNETDEVCTL, using auto"
            case "$driver" in
                cdc_ether|rndis_host)
                    return 0
                    ;;
            esac
            ;;
    esac

    return 1
}

start_at_netdev_session() {
    local driver=$1
    local port
    local response

    qnetdevctl_enabled "$driver" || return 0

    if [ -c "$AT_DEVICE" ]; then
        log "Starting ECM/RNDIS data call on $NET_IFACE with AT+QNETDEVCTL via $AT_DEVICE"
        response=$(send_at "$AT_DEVICE" "AT+QNETDEVCTL=1,1,1" 10 2>/dev/null) || {
            log "WARNING: AT+QNETDEVCTL failed on $AT_DEVICE"
            return 1
        }

        log "AT+QNETDEVCTL=1,1,1 response: $(printf '%s' "$response" | compact_text)"
        echo "$response" | grep -q OK
        return $?
    fi

    if [ ! -c "$AT_DEVICE" ]; then
        port=$(find_at_port) || {
            log "WARNING: No AT port found by probe, trying AT+QNETDEVCTL on all candidates"
            while IFS= read -r port; do
                log "Trying AT+QNETDEVCTL=1,1,1 on $port"
                response=$(send_at "$port" "AT+QNETDEVCTL=1,1,1" 10 2>/dev/null) || {
                    log "WARNING: AT+QNETDEVCTL failed on $port"
                    continue
                }

                log "AT+QNETDEVCTL=1,1,1 response on $port: $(printf '%s' "$response" | compact_text)"
                if echo "$response" | grep -q OK; then
                    AT_DEVICE="$port"
                    return 0
                fi
            done <<EOF
$(at_port_candidates)
EOF

            return 1
        }
        AT_DEVICE="$port"
    fi

    log "Starting ECM/RNDIS data call on $NET_IFACE with AT+QNETDEVCTL via $AT_DEVICE"
    response=$(send_at "$AT_DEVICE" "AT+QNETDEVCTL=1,1,1" 10 2>/dev/null) || {
        log "WARNING: AT+QNETDEVCTL failed on $AT_DEVICE"
        return 1
    }

    log "AT+QNETDEVCTL=1,1,1 response: $(printf '%s' "$response" | compact_text)"
    echo "$response" | grep -q OK
}

start_wwan() {
    local driver

    wait_for_wwan_ready || return 1
    setup_module_at || true

    ip link set "$NET_IFACE" up || {
        log "ERROR: Failed to bring up $NET_IFACE"
        return 1
    }

    driver=$(get_iface_driver "$NET_IFACE" 2>/dev/null || echo unknown)
    if [ "$driver" = "qmi_wwan" ]; then
        start_qmi_session || return 1
    else
        start_at_netdev_session "$driver" || \
            log "WARNING: Continuing DHCP after AT+QNETDEVCTL did not return OK"
    fi

    sleep "$NET_START_GRACE"
    wwan_is_connected && {
        log "$NET_IFACE already has IPv4: $(get_iface_ipv4 "$NET_IFACE")"
        ensure_network_defaults
        return 0
    }

    run_dhcp
}

stop_qmicli() {
    local qmicli_bin
    local cid=""
    local pdh=""

    [ -s "$QMI_STATE_FILE" ] || return 0
    qmicli_bin=$(find_cmd qmicli) || return 0

    . "$QMI_STATE_FILE"
    cid=${CID:-}
    pdh=${PDH:-}

    if [ -n "$cid" ] && [ -n "$pdh" ] && [ -c "$WDM_DEVICE" ]; then
        "$qmicli_bin" -d "$WDM_DEVICE" --device-open-proxy \
            --wds-stop-network="$pdh" --client-cid="$cid" >/dev/null 2>&1 || true
    fi

    rm -f "$QMI_STATE_FILE"
}

stop_wwan() {
    log "Stopping 4G WWAN session"

    pkill quectel-CM 2>/dev/null || true
    stop_qmicli

    if command -v dhclient >/dev/null 2>&1; then
        dhclient -r "$NET_IFACE" >/dev/null 2>&1 || true
    fi

    ip link set "$NET_IFACE" down >/dev/null 2>&1 || true
}

monitor_4g() {
    local fail_count=0
    local sleep_time

    log "Starting 4G WWAN monitor, iface=$NET_IFACE wdm=$WDM_DEVICE"

    while true; do
        if is_4g_module; then
            if ! wwan_is_connected; then
                log "4G WWAN link is not connected, starting"
                if start_wwan; then
                    fail_count=0
                else
                    fail_count=$((fail_count + 1))
                    log "WARNING: 4G WWAN start failed, consecutive_failures=$fail_count"
                fi
            fi
        else
            log "4G module not detected"
        fi

        sleep_time=$((MONITOR_INTERVAL * (fail_count + 1)))
        [ "$sleep_time" -gt "$MAX_RETRY_INTERVAL" ] && sleep_time=$MAX_RETRY_INTERVAL
        sleep "$sleep_time"
    done
}

case "$1" in
    start)
        start_wwan
        ;;
    monitor)
        monitor_4g
        ;;
    stop)
        stop_wwan
        ;;
    restart|reload)
        stop_wwan
        start_wwan
        ;;
    *)
        echo "Usage: $0 {start|monitor|stop|restart}"
        exit 1
        ;;
esac

exit $?
