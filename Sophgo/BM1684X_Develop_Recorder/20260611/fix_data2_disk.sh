#!/bin/bash

DEV="/dev/sda1"
DISK="/dev/sda"
MNT="/data2"
BAK="/data/data2_backup"
TMP_EXTRACT="/tmp/fix_hwfp_extract"
LOG="/var/log/fix-data2-disk.log"
LOCK="/var/run/fix-data2-disk.lock"

MACHINE_CODE=""

log()
{
    echo "$(date '+%F %T') $*" | tee -a "$LOG"
    logger -t fix-data2 "$*" 2>/dev/null || true
}

die()
{
    log "ERROR: $*"
    exit 1
}

usage()
{
    cat <<EOF_USAGE
Usage:
  $0 --yes [--code MACHINE_CODE]

Example:
  $0 --yes --code TE1001S2605250040

说明:
  该脚本用于补救产线 /data2 未挂载硬盘时，hwfp.dat 被误写入 eMMC /data2 的情况。

最终目标:
  确保 /dev/sda1 挂载到 /data2
  确保 /data2/<机器码>.dat 存在

脚本会尝试从以下位置寻找 hwfp.dat:
  1. eMMC 底层 /data2
  2. /data
  3. /data 的子目录
  4. /data/hwfp.zip 解压结果
  5. /home/linaro
  6. 已挂载硬盘 /data2

警告:
  如果 /dev/sda1 无有效文件系统，或者已有文件系统无法挂载，脚本会格式化 /dev/sda1。
EOF_USAGE
}

parse_args()
{
    [ "$#" -ge 1 ] || {
        usage
        exit 1
    }

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes)
                shift
                ;;
            --code)
                [ -n "${2:-}" ] || die "--code requires argument"
                MACHINE_CODE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

is_mountpoint()
{
    awk -v mp="$1" '$2 == mp {found=1} END{exit found?0:1}' /proc/mounts
}

get_mount_src()
{
    awk -v mp="$1" '$2 == mp {print $1}' /proc/mounts | tail -n 1
}

same_dev()
{
    local a="$1"
    local b="$2"

    [ -e "$a" ] || return 1
    [ -e "$b" ] || return 1

    [ "$(readlink -f "$a" 2>/dev/null)" = "$(readlink -f "$b" 2>/dev/null)" ]
}

get_dev_mountpoint()
{
    local dev="$1"
    local src
    local mp

    while read -r src mp _rest; do
        if same_dev "$src" "$dev"; then
            echo "$mp"
            return 0
        fi
    done < /proc/mounts

    return 1
}

dir_not_empty()
{
    [ -d "$1" ] && [ "$(ls -A "$1" 2>/dev/null)" ]
}

copy_dir()
{
    local src="$1"
    local dst="$2"

    mkdir -p "$dst" || return 1

    if command -v rsync >/dev/null 2>&1; then
        rsync -aHAX --numeric-ids "$src"/ "$dst"/
    else
        cp -a "$src"/. "$dst"/
    fi
}

check_space()
{
    local src="$1"
    local dst_parent="$2"
    local need_k
    local avail_k

    need_k="$(du -sk "$src" 2>/dev/null | awk '{print $1}')"
    [ -n "$need_k" ] || need_k=0

    avail_k="$(df -Pk "$dst_parent" 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$avail_k" ] || die "cannot get available space of $dst_parent"

    log "backup need ${need_k}KB, available ${avail_k}KB on $dst_parent"

    if [ "$need_k" -gt 0 ]; then
        need_k=$((need_k + 10240))
    fi

    [ "$avail_k" -gt "$need_k" ] || die "not enough space on $dst_parent for backup"
}

trigger_udev()
{
    log "reload udev rules"
    udevadm control --reload-rules 2>/dev/null || true

    log "trigger udev add event for sda1"

    if command -v udevadm >/dev/null 2>&1; then
        if udevadm trigger --action=add --subsystem-match=block --sysname-match=sda1 2>/dev/null; then
            udevadm settle 2>/dev/null || true
            return 0
        fi
    fi

    log "udevadm trigger failed or unsupported, try sysfs uevent"
    echo add > /sys/class/block/sda1/uevent 2>/dev/null || true
    udevadm settle 2>/dev/null || true
}

wait_for_dev()
{
    local i=0

    while [ $i -lt 10 ]; do
        [ -b "$DEV" ] && return 0
        sleep 1
        i=$((i + 1))
    done

    return 1
}

mount_dev_to_data2()
{
    local mnt_src
    local dev_mp

    mkdir -p "$MNT" || return 1

    trigger_udev
    sleep 2

    mnt_src="$(get_mount_src "$MNT" || true)"
    if [ -n "$mnt_src" ] && same_dev "$mnt_src" "$DEV"; then
        log "udev mounted $DEV to $MNT successfully"
        return 0
    fi

    dev_mp="$(get_dev_mountpoint "$DEV" || true)"
    if [ -n "$dev_mp" ]; then
        log "$DEV was mounted on $dev_mp, unmount it and remount to $MNT"
        umount "$dev_mp" >> "$LOG" 2>&1 || return 1
    fi

    log "manual mount $DEV to $MNT"
    mount "$DEV" "$MNT" >> "$LOG" 2>&1 || return 1

    mnt_src="$(get_mount_src "$MNT" || true)"
    [ -n "$mnt_src" ] && same_dev "$mnt_src" "$DEV"
}

try_get_code_from_history()
{
    local code=""

    for h in /root/.bash_history /home/linaro/.bash_history; do
        [ -f "$h" ] || continue

        code="$(grep -E "oem_ops[[:space:]]+write[[:space:]]+0[[:space:]]+-s" "$h" 2>/dev/null | tail -n 1 | \
            sed -n 's/.*write[[:space:]]*0[[:space:]]*-s[[:space:]]*\([^[:space:]]*\).*/\1/p')"

        if [ -n "$code" ]; then
            echo "$code"
            return 0
        fi
    done

    return 1
}

try_get_code_from_oem_ops()
{
    local op
    local out
    local code

    for op in /data/oem_ops /home/linaro/oem_ops /usr/bin/oem_ops /usr/sbin/oem_ops ./oem_ops; do
        [ -x "$op" ] || continue

        out="$("$op" read 0 2>/dev/null || true)"
        [ -n "$out" ] || continue

        code="$(echo "$out" | grep -oE '[A-Za-z0-9_-]{8,64}' | grep -E '[0-9]' | tail -n 1)"

        if [ -n "$code" ]; then
            echo "$code"
            return 0
        fi
    done

    return 1
}

get_machine_code()
{
    local code=""

    if [ -n "$MACHINE_CODE" ]; then
        echo "$MACHINE_CODE"
        return 0
    fi

    code="$(try_get_code_from_history 2>/dev/null || true)"
    if [ -n "$code" ]; then
        echo "$code"
        return 0
    fi

    code="$(try_get_code_from_oem_ops 2>/dev/null || true)"
    if [ -n "$code" ]; then
        echo "$code"
        return 0
    fi

    return 1
}

find_hwfp_dat()
{
    local f

    # 1. 优先找备份出来的 eMMC /data2 内容
    if [ -f "$BAK/hwfp.dat" ]; then
        echo "$BAK/hwfp.dat"
        return 0
    fi

    # 2. 如果已经存在任意 dat，且不是目标文件，也作为候选
    f="$(find "$BAK" -maxdepth 2 -type f -name "*.dat" 2>/dev/null | head -n 1)"
    if [ -n "$f" ]; then
        echo "$f"
        return 0
    fi

    # 3. /data 下面直接有 hwfp.dat
    if [ -f /data/hwfp.dat ]; then
        echo /data/hwfp.dat
        return 0
    fi

    # 4. /data 子目录里有 hwfp.dat
    f="$(find /data -maxdepth 3 -type f -name "hwfp.dat" 2>/dev/null | head -n 1)"
    if [ -n "$f" ]; then
        echo "$f"
        return 0
    fi

    # 5. /home/linaro 下有 hwfp.dat
    if [ -f /home/linaro/hwfp.dat ]; then
        echo /home/linaro/hwfp.dat
        return 0
    fi

    f="$(find /home/linaro -maxdepth 3 -type f -name "hwfp.dat" 2>/dev/null | head -n 1)"
    if [ -n "$f" ]; then
        echo "$f"
        return 0
    fi

    # 6. /data2 当前硬盘上已有 hwfp.dat
    if [ -f "$MNT/hwfp.dat" ]; then
        echo "$MNT/hwfp.dat"
        return 0
    fi

    return 1
}

try_unzip_hwfp()
{
    local zip=""
    local f=""

    command -v unzip >/dev/null 2>&1 || {
        log "unzip not found, skip unzip"
        return 1
    }

    rm -rf "$TMP_EXTRACT"
    mkdir -p "$TMP_EXTRACT" || return 1

    if [ -f /data/hwfp.zip ]; then
        zip="/data/hwfp.zip"
    else
        zip="$(find /data /home/linaro -maxdepth 3 -type f -name "hwfp.zip" 2>/dev/null | head -n 1)"
    fi

    [ -n "$zip" ] || return 1

    log "found zip: $zip, unzip to $TMP_EXTRACT"
    unzip -o "$zip" -d "$TMP_EXTRACT" >> "$LOG" 2>&1 || return 1

    f="$(find "$TMP_EXTRACT" -type f -name "hwfp.dat" 2>/dev/null | head -n 1)"
    [ -n "$f" ] || return 1

    echo "$f"
    return 0
}

install_machine_dat()
{
    local code="$1"
    local target="$MNT/${code}.dat"
    local src=""

    log "target machine dat: $target"

    if [ -f "$target" ]; then
        log "$target already exists"
        chown linaro:linaro "$target" 2>/dev/null || true
        chmod 644 "$target" 2>/dev/null || true
        return 0
    fi

    src="$(find_hwfp_dat 2>/dev/null || true)"

    if [ -z "$src" ]; then
        src="$(try_unzip_hwfp 2>/dev/null || true)"
    fi

    [ -n "$src" ] || die "cannot find hwfp.dat or hwfp.zip, cannot create $target"

    log "use source hwfp file: $src"
    cp -a "$src" "$target" || die "copy $src to $target failed"

    chown linaro:linaro "$target" 2>/dev/null || true
    chmod 644 "$target" 2>/dev/null || true
    sync

    [ -f "$target" ] || die "$target not created"

    log "create $target success"
}

backup_hidden_data2()
{
    [ -d /data ] || die "/data not found"
    is_mountpoint /data || log "WARN: /data is not a separate mountpoint"

    if [ -e "$BAK" ]; then
        if is_mountpoint "$BAK"; then
            die "$BAK is a mountpoint, abort"
        fi

        if dir_not_empty "$BAK"; then
            die "$BAK already exists and is not empty, abort"
        fi
    fi

    mkdir -p "$BAK" || die "mkdir $BAK failed"

    log "hidden underlay $MNT content:"
    ls -la "$MNT" 2>&1 | tee -a "$LOG" || true

    if dir_not_empty "$MNT"; then
        check_space "$MNT" /data
        log "backup hidden eMMC $MNT to $BAK"
        copy_dir "$MNT" "$BAK" || die "backup $MNT to $BAK failed"
    else
        log "hidden eMMC $MNT is empty, skip backup"
    fi

    sync
}

restore_backup_to_mounted_data2()
{
    if dir_not_empty "$BAK"; then
        log "restore $BAK to $MNT"
        copy_dir "$BAK" "$MNT" || die "restore $BAK to $MNT failed"
    else
        log "$BAK is empty, skip restore"
    fi

    sync
}

cleanup_backup()
{
    log "remove backup dir $BAK"
    rm -rf "$BAK" || die "remove $BAK failed"
}

final_info()
{
    log "final blkid:"
    blkid "$DEV" 2>&1 | tee -a "$LOG" || true

    log "final mount:"
    mount | grep -E "$DEV|$MNT" | tee -a "$LOG" || true

    log "final df:"
    df -h "$MNT" 2>&1 | tee -a "$LOG" || true

    log "final /data2 files:"
    ls -la "$MNT" 2>&1 | tee -a "$LOG" || true
}

main()
{
    parse_args "$@"

    [ "$(id -u)" = "0" ] || die "must run as root"

    cd / || die "cd / failed"

    if ! mkdir "$LOCK" 2>/dev/null; then
        die "another fix-data2-disk.sh is running"
    fi
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

    log "========== start fix-data2-disk =========="

    command -v mkfs.ext4 >/dev/null 2>&1 || die "mkfs.ext4 not found"
    command -v blkid >/dev/null 2>&1 || die "blkid not found"

    [ -b "$DISK" ] || die "$DISK not found"
    wait_for_dev || die "$DEV not found"

    mkdir -p "$MNT" || die "mkdir $MNT failed"

    log "current lsblk:"
    lsblk -fp "$DISK" 2>&1 | tee -a "$LOG" || true

    log "current blkid:"
    blkid "$DEV" 2>&1 | tee -a "$LOG" || true

    CODE="$(get_machine_code 2>/dev/null || true)"
    [ -n "$CODE" ] || die "cannot get machine code, please run with --code MACHINE_CODE"

    log "machine code: $CODE"

    mnt_src="$(get_mount_src "$MNT" || true)"
    if [ -n "$mnt_src" ]; then
        if same_dev "$mnt_src" "$DEV"; then
            log "$MNT is currently mounted by $DEV"
            log "temporarily unmount $MNT to check hidden eMMC underlay files"
            umount "$MNT" >> "$LOG" 2>&1 || die "umount $MNT failed, maybe busy"
        else
            die "$MNT is mounted by $mnt_src, not $DEV, abort"
        fi
    fi

    backup_hidden_data2

    FSTYPE="$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)"
    log "$DEV filesystem type: '${FSTYPE}'"

    case "$FSTYPE" in
        ext4|ext3|ext2|vfat|fat)
            log "$DEV already has supported filesystem TYPE=$FSTYPE, try mount first"

            if mount_dev_to_data2; then
                log "$DEV mounted to $MNT without formatting"
            else
                log "mount existing filesystem TYPE=$FSTYPE failed, will format $DEV as ext4"
                log "format $DEV as ext4"
                umount "$DEV" 2>/dev/null || true
                mkfs.ext4 -F "$DEV" >> "$LOG" 2>&1 || die "mkfs.ext4 $DEV failed"
                sync

                log "after mkfs blkid:"
                blkid "$DEV" 2>&1 | tee -a "$LOG" || true

                mount_dev_to_data2 || die "mount $DEV to $MNT failed after mkfs"
            fi
            ;;
        "")
            log "$DEV has no filesystem TYPE, will format $DEV as ext4"
            umount "$DEV" 2>/dev/null || true
            mkfs.ext4 -F "$DEV" >> "$LOG" 2>&1 || die "mkfs.ext4 $DEV failed"
            sync

            log "after mkfs blkid:"
            blkid "$DEV" 2>&1 | tee -a "$LOG" || true

            mount_dev_to_data2 || die "mount $DEV to $MNT failed after mkfs"
            ;;
        *)
            die "$DEV has unsupported filesystem TYPE=$FSTYPE, abort to avoid data loss"
            ;;
    esac

    mnt_src="$(get_mount_src "$MNT" || true)"
    [ -n "$mnt_src" ] || die "$MNT is still not mounted"

    if ! same_dev "$mnt_src" "$DEV"; then
        die "$MNT mounted by $mnt_src, not $DEV"
    fi

    log "$DEV mounted on $MNT confirmed"

    restore_backup_to_mounted_data2

    install_machine_dat "$CODE"

    cleanup_backup
    final_info

    log "========== fix-data2-disk done =========="
    exit 0
}

main "$@"