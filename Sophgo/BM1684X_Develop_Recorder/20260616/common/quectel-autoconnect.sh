#!/bin/bash

AT_DEVICE="${QUECTEL_AT_DEVICE:-}"
BAUDRATE="${QUECTEL_BAUDRATE:-115200}"
FORCE_MODE="${QUECTEL_MODE:-auto}"

QMI_IFACE="${QUECTEL_QMI_IFACE:-wwan0}"
WDM_DEVICE="${QUECTEL_WDM_DEVICE:-/dev/cdc-wdm0}"
QMI_STATE_FILE="${QUECTEL_QMI_STATE_FILE:-/run/quectel-qmi.state}"

DEVICE_TIMEOUT="${QUECTEL_DEVICE_TIMEOUT:-30}"
NCM_IFACE_TIMEOUT="${QUECTEL_NCM_IFACE_TIMEOUT:-180}"
NCM_CARRIER_TIMEOUT="${QUECTEL_NCM_CARRIER_TIMEOUT:-480}"
MONITOR_INTERVAL="${QUECTEL_MONITOR_INTERVAL:-10}"
NET_START_GRACE="${QUECTEL_NET_START_GRACE:-5}"
DHCP_TIMEOUT="${QUECTEL_DHCP_TIMEOUT:-30}"
MAX_RETRY_INTERVAL="${QUECTEL_MAX_RETRY_INTERVAL:-60}"

APN="${QUECTEL_APN:-}"
FALLBACK_DNS="${QUECTEL_FALLBACK_DNS:-114.114.114.114 223.5.5.5}"
LOG_FILE="${QUECTEL_LOG_FILE:-/var/log/quectel-autoconnect.log}"

# Known 4G IDs from the original QMI script. Add RG200/5G IDs in the env file if needed.
QUECTEL_4G_USB_IDS="${QUECTEL_4G_USB_IDS:-2c7c:0125 2c7c:0121 05c6:9215}"
QUECTEL_5G_USB_IDS="${QUECTEL_5G_USB_IDS:-2c7c:0900}"

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

# 通过 USB VID:PID 判断设备是否存在
usb_id_present() {
    local wanted=$1
    local vid=${wanted%:*}
    local pid=${wanted#*:}
    local dev
    local dev_vid
    local dev_pid

    for dev in /sys/bus/usb/devices/*; do
        [ -r "$dev/idVendor" ] || continue
        [ -r "$dev/idProduct" ] || continue
        dev_vid=$(cat "$dev/idVendor")
        dev_pid=$(cat "$dev/idProduct")
        [ "$dev_vid" = "$vid" ] || continue
        [ "$pid" = "*" ] || [ "$dev_pid" = "$pid" ] || continue
        return 0
    done

    return 1
}

# 在支持表中查询 ID 是否存在
usb_ids_present() {
    local id

    for id in $1; do
        usb_id_present "$id" && return 0
    done

    return 1
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
    stty -F "$port" "$BAUDRATE" raw -echo -echoe -echok 2>/dev/null || return 1

    exec 3<>"$port" || return 1
    printf '%s\r' "$command" >&3
    end=$((SECONDS + timeout))

    while [ "$SECONDS" -lt "$end" ]; do
        if IFS= read -r -t 1 line <&3; then
            output="${output}${line}"$'\n'
            case "$line" in
                *OK*|*ERROR*) break ;;
            esac
        fi
    done

    exec 3<&-
    exec 3>&-
    printf '%s' "$output"
}

find_at_port() {
    local port
    local response

    if [ -n "$AT_DEVICE" ]; then
        [ -c "$AT_DEVICE" ] && echo "$AT_DEVICE" && return 0
        return 1
    fi

    for port in /dev/serial/by-id/*Quectel* /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB1 /dev/ttyUSB0; do
        [ -e "$port" ] || continue
        port=$(readlink -f "$port")
        [ -c "$port" ] || continue

        response=$(send_at "$port" AT 2 2>/dev/null) || continue
        echo "$response" | grep -q OK || continue
        echo "$port"
        return 0
    done

    return 1
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

setup_module_at() {
    local port

    port=$(find_at_port) || {
        log "WARNING: No responsive AT port found"
        return 1
    }

    AT_DEVICE="$port"
    log "Checking module by AT on $AT_DEVICE"
    log_at AT 3 || return 1
    log_at "AT+CPIN?" 5 || true
    log_at "AT+CSQ" 5 || true
    log_at "AT+COPS?" 5 || true
    log_at "AT+CGATT?" 5 || true

    if [ -n "$APN" ]; then
        log "Configuring PDP context by APN: $APN"
        log_at "AT+CGDCONT=1,\"IP\",\"$APN\"" 5 || true
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

# 查找接口判断驱动
find_ifaces_by_driver() {
    local wanted_driver=$1
    local iface
    local driver

    for iface in /sys/class/net/*; do
        iface=${iface##*/}
        [ "$iface" = "lo" ] && continue
        [ -e "/sys/class/net/$iface/device/driver" ] || continue

        driver=$(get_iface_driver "$iface" 2>/dev/null || true)
        [ "$driver" = "$wanted_driver" ] && echo "$iface"
    done
}

# 查找 cdc_ncm 接口
find_ncm_ifaces() {
    find_ifaces_by_driver cdc_ncm
}

# 查找 qmi_wwan 接口
qmi_iface_ready() {
    [ -d "/sys/class/net/$QMI_IFACE" ] || return 1
    [ "$(get_iface_driver "$QMI_IFACE" 2>/dev/null || true)" = "qmi_wwan" ]
}

get_iface_ipv4() {
    local iface=$1

    ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR == 1 {print $4}'
}

iface_is_connected() {
    local iface=$1

    [ -d "/sys/class/net/$iface" ] || return 1
    [ -n "$(get_iface_ipv4 "$iface")" ]
}

has_default_route() {
    ip route show default 2>/dev/null | grep -q '^default '
}

install_default_route() {
    local iface=$1

    has_default_route && return 0

    log "No default route found, installing default dev $iface"
    ip route replace default dev "$iface" metric 50 || {
        log "WARNING: Failed to install default route dev $iface"
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
    local iface=$1
    local ns

    if command -v resolvectl >/dev/null 2>&1; then
        log "Installing DNS on $iface with resolvectl: $FALLBACK_DNS"
        resolvectl dns "$iface" $FALLBACK_DNS >/dev/null 2>&1 || \
            log "WARNING: resolvectl dns failed on $iface"
        resolvectl domain "$iface" "~." >/dev/null 2>&1 || true
        resolvectl default-route "$iface" yes >/dev/null 2>&1 || true
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
    local iface=$1

    install_default_route "$iface" || true
    install_fallback_dns "$iface" || true
}

wait_for_ipv4() {
    local iface=$1
    local counter=0

    while ! iface_is_connected "$iface" && [ "$counter" -lt "$DHCP_TIMEOUT" ]; do
        sleep 1
        counter=$((counter + 1))
    done

    iface_is_connected "$iface"
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

    wait_for_ipv4 "$iface" || {
        log "WARNING: $iface has no IPv4 address after DHCP"
        return 1
    }

    log "$iface IPv4 is ready: $(get_iface_ipv4 "$iface")"
    ensure_network_defaults "$iface"
}

wait_for_carrier() {
    local iface=$1
    local counter=0

    if [ ! -r "/sys/class/net/$iface/carrier" ]; then
        log "WARNING: Cannot read carrier state for $iface"
        return 1
    fi

    while [ "$(cat "/sys/class/net/$iface/carrier")" = "0" ] && [ "$counter" -lt "$NCM_CARRIER_TIMEOUT" ]; do
        sleep 1
        counter=$((counter + 1))
    done

    [ "$(cat "/sys/class/net/$iface/carrier")" != "0" ] || {
        log "WARNING: $iface has no carrier after ${NCM_CARRIER_TIMEOUT} seconds"
        return 1
    }

    log "$iface carrier is ready"
}

start_quectel_cm() {
    local iface=$1
    local mode=$2
    local cm_bin

    cm_bin=$(find_cmd quectel-CM) || return 1

    if pidof quectel-CM >/dev/null 2>&1; then
        log "quectel-CM is already running"
        return 0
    fi

    if [ "$mode" = "qmi" ]; then
        if [ -n "$APN" ]; then
            log "Starting quectel-CM QMI on $iface with APN: $APN"
            nohup "$cm_bin" -i "$iface" -s "$APN" >> "$LOG_FILE" 2>&1 &
        else
            log "Starting quectel-CM QMI on $iface with module default APN"
            nohup "$cm_bin" -i "$iface" >> "$LOG_FILE" 2>&1 &
        fi
    else
        log "Starting quectel-CM NCM"
        nohup "$cm_bin" >> "$LOG_FILE" 2>&1 &
    fi

    sleep "$NET_START_GRACE"

    if ! pidof quectel-CM >/dev/null 2>&1; then
        log "WARNING: quectel-CM exited shortly after start"
        return 1
    fi
}

set_qmi_raw_ip() {
    local raw_ip="/sys/class/net/$QMI_IFACE/qmi/raw_ip"

    [ -w "$raw_ip" ] || return 0

    ip link set "$QMI_IFACE" down >/dev/null 2>&1 || true
    if echo Y > "$raw_ip" 2>/dev/null; then
        log "Enabled QMI raw_ip on $QMI_IFACE"
    else
        log "WARNING: Failed to enable QMI raw_ip on $QMI_IFACE"
    fi
}

start_qmicli() {
    local qmicli_bin
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

    if [ -n "$APN" ]; then
        request="apn='$APN',ip-type=4"
        log "Starting QMI network with qmicli, APN=$APN"
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

wait_for_qmi_ready() {
    local counter=0

    while [ "$counter" -lt "$DEVICE_TIMEOUT" ]; do
        if qmi_iface_ready; then
            log "4G QMI interface ready: $QMI_IFACE"
            return 0
        fi

        sleep 1
        counter=$((counter + 1))
    done

    log "ERROR: QMI interface not ready, iface=$QMI_IFACE"
    return 1
}

# 开启 4G QMI 网络
start_4g_qmi() {
    wait_for_qmi_ready || return 1
    setup_module_at || true

    set_qmi_raw_ip
    ip link set "$QMI_IFACE" up || {
        log "ERROR: Failed to bring up $QMI_IFACE"
        return 1
    }

    if ! start_quectel_cm "$QMI_IFACE" qmi; then
        start_qmicli || {
            log "ERROR: qmi_wwan requires quectel-CM or qmicli/libqmi-utils to start data session"
            return 1
        }
    fi

    sleep "$NET_START_GRACE"
    iface_is_connected "$QMI_IFACE" && {
        log "$QMI_IFACE already has IPv4: $(get_iface_ipv4 "$QMI_IFACE")"
        ensure_network_defaults "$QMI_IFACE"
        return 0
    }

    run_dhcp "$QMI_IFACE"
}

wait_for_ncm_ready() {
    local counter=0

    while [ -z "$(find_ncm_ifaces)" ] && [ "$counter" -lt "$NCM_IFACE_TIMEOUT" ]; do
        sleep 1
        counter=$((counter + 1))
    done

    [ -n "$(find_ncm_ifaces)" ] || {
        log "ERROR: No cdc_ncm interface found after ${NCM_IFACE_TIMEOUT} seconds"
        return 1
    }

    log "5G NCM interface ready: $(find_ncm_ifaces)"
}

# 开始 5G NCM 
start_5g_ncm() {
    local iface
    local found=0

    wait_for_ncm_ready || return 1
    setup_module_at || true
    start_quectel_cm "" ncm || return 1

    for iface in $(find_ncm_ifaces); do
        found=1
        log "Bringing up 5G NCM interface $iface"
        ip link set "$iface" up || {
            log "ERROR: Failed to bring up $iface"
            continue
        }

        if wait_for_carrier "$iface"; then
            run_dhcp "$iface" && return 0
        fi
    done

    [ "$found" -eq 1 ] || log "ERROR: No cdc_ncm interface found"
    return 1
}

# 检测是否是4G或5G模块，返回qmi或ncm
detect_mode() {
    case "$FORCE_MODE" in
        4g|qmi)
            echo qmi
            return 0
            ;;
        5g|ncm)
            echo ncm
            return 0
            ;;
        auto|"")
            ;;
        *)
            log "WARNING: Unknown QUECTEL_MODE=$FORCE_MODE, fallback to auto"
            ;;
    esac

    if [ -n "$(find_ncm_ifaces)" ]; then
        echo ncm
        return 0
    fi

    if qmi_iface_ready; then
        echo qmi
        return 0
    fi

    if usb_ids_present "$QUECTEL_5G_USB_IDS"; then
        echo ncm
        return 0
    fi

    if usb_ids_present "$QUECTEL_4G_USB_IDS"; then
        echo qmi
        return 0
    fi

    return 1
}

# 自动开始
start_auto() {
    local mode

    mode=$(detect_mode) || {
        log "Module not detected yet"
        return 1
    }

    case "$mode" in
        ncm)
            log "Detected 5G/NCM module"
            start_5g_ncm
            ;;
        qmi)
            log "Detected 4G/QMI module"
            start_4g_qmi
            ;;
        *)
            log "ERROR: Unsupported mode: $mode"
            return 1
            ;;
    esac
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

stop_auto() {
    local iface

    log "Stopping Quectel data session"
    pkill quectel-CM 2>/dev/null || true
    stop_qmicli

    if command -v dhclient >/dev/null 2>&1; then
        dhclient -r "$QMI_IFACE" >/dev/null 2>&1 || true
        for iface in $(find_ncm_ifaces); do
            dhclient -r "$iface" >/dev/null 2>&1 || true
        done
    fi

    ip link set "$QMI_IFACE" down >/dev/null 2>&1 || true
    for iface in $(find_ncm_ifaces); do
        ip link set "$iface" down >/dev/null 2>&1 || true
    done
}

any_data_connected() {
    local iface

    iface_is_connected "$QMI_IFACE" && return 0

    for iface in $(find_ncm_ifaces); do
        iface_is_connected "$iface" && return 0
    done

    return 1
}

monitor_auto() {
    local fail_count=0
    local sleep_time

    log "Starting Quectel 4G/5G monitor, mode=$FORCE_MODE qmi_iface=$QMI_IFACE wdm=$WDM_DEVICE"

    while true; do
        if ! any_data_connected; then
            log "Cellular link is not connected, starting"
            if start_auto; then
                fail_count=0
            else
                fail_count=$((fail_count + 1))
                log "WARNING: Cellular start failed, consecutive_failures=$fail_count"
            fi
        fi

        sleep_time=$((MONITOR_INTERVAL * (fail_count + 1)))
        [ "$sleep_time" -gt "$MAX_RETRY_INTERVAL" ] && sleep_time=$MAX_RETRY_INTERVAL
        sleep "$sleep_time"
    done
}

case "$1" in
    start)
        start_auto
        ;;
    monitor)
        monitor_auto
        ;;
    stop)
        stop_auto
        ;;
    restart|reload)
        stop_auto
        start_auto
        ;;
    *)
        echo "Usage: $0 {start|monitor|stop|restart}"
        exit 1
        ;;
esac

exit $?
