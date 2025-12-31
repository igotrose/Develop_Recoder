#!/bin/bash

# Ensure the path ends with a slash
normalize_path() {
    if [[ "$1" != */ ]]; then
        echo "${1}/"
    else
        echo "$1"
    fi
}

mnt() {
    local MOUNT_PATH=$(normalize_path "$2")

    echo "=> Mounting essential filesystems at $MOUNT_PATH"

    # Check if directory exists
    if [ ! -d "$MOUNT_PATH" ]; then
        echo "ERROR: Directory $MOUNT_PATH does not exist."
        exit 1
    fi

    # Create necessary dirs if missing
    mkdir -p "${MOUNT_PATH}proc" "${MOUNT_PATH}sys" "${MOUNT_PATH}dev" "${MOUNT_PATH}dev/pts" "${MOUNT_PATH}tmp"

    # Mount virtual filesystems
    sudo mount -t proc   /proc           "${MOUNT_PATH}proc"     || echo "proc already mounted?"
    sudo mount -t sysfs  /sys            "${MOUNT_PATH}sys"      || echo "sysfs already mounted?"
    sudo mount -o bind   /dev            "${MOUNT_PATH}dev"      || echo "dev bind mount failed or already exists"
    sudo mount -o bind   /dev/pts        "${MOUNT_PATH}dev/pts"  || echo "dev/pts already mounted?"
    sudo mount -t tmpfs  -o mode=1777,tmpcopyup tmpfs "${MOUNT_PATH}tmp" || echo "tmpfs for /tmp failed"

    echo "✅ Mounting completed."
    echo "👉 You can now run: sudo chroot ${MOUNT_PATH}"
}

umnt() {
    local MOUNT_PATH=$(normalize_path "$2")

    echo "=> Unmounting from $MOUNT_PATH"

    # Reverse order is safer
    sudo umount "${MOUNT_PATH}tmp"       || echo "Not mounted: tmp"
    sudo umount "${MOUNT_PATH}dev/pts"   || echo "Not mounted: dev/pts"
    sudo umount "${MOUNT_PATH}dev"       || echo "Not mounted: dev"
    sudo umount "${MOUNT_PATH}sys"       || echo "Not mounted: sys"
    sudo umount "${MOUNT_PATH}proc"      || echo "Not mounted: proc"

    echo "✅ Unmounting completed."
}

usage() {
    echo ""
    echo "Usage: $0 [option] [rootfs_path]"
    echo ""
    echo "Options:"
    echo "  -m <path>    Mount proc, sys, dev, dev/pts, and tmp into rootfs"
    echo "  -u <path>    Unmount all above"
    echo ""
    echo "Example:"
    echo "  $0 -m /media/ubuntu_rootfs/"
    echo "  $0 -u /media/ubuntu_rootfs/"
    echo ""
}

# Main logic
if [ "$#" -ne 2 ]; then
    usage
    exit 1
fi

case "$1" in
    -m)
        mnt "$1" "$2"
        ;;
    -u)
        umnt "$1" "$2"
        ;;
    *)
        echo "Invalid option: $1"
        usage
        exit 1
        ;;
esac