#!/bin/sh

# First Boot Init Script
# - Resizes root filesystem to full partition size
# - Formats and mounts /data partition (mmcblk0p8)
# - Ensures /data uses full space (online resize)
# - Creates symlink /home/ubuntu/data -> /data
# - Logs completion and marks success

set -e

# log output
LOGFILE="/var/log/firstboot-init.log"
exec >> "$LOGFILE" 2>&1
echo "=== First Boot Init Starting at $(date) ==="

# === 1. Resize root filesystem ===
root_dev=$(findmnt -n -o SOURCE /)
echo "Root device: $root_dev"
echo "Resizing root filesystem..."
if resize2fs "$root_dev"; then
    echo "OK: Root resized successfully."
else
    echo "ERROR: resize2fs failed on $root_dev"
    exit 1
fi

# === 2. Setup /data partition ===
data_part="/dev/mmcblk0p8"

# check if device exist
if [ ! -b "$data_part" ]; then
    echo "ERROR: $data_part does not exist or is not a block device"
    exit 1
fi

# check if partition is formatted as ext4
if ! blkid "$data_part" | grep -q 'TYPE="ext4"'; then
    echo "Formatting $data_part as ext4 with label 'userdata'..."
    mkfs.ext4 -F -L userdata "$data_part"
    echo "OK: $data_part formatted."
else
    echo "INFO: $data_part already formatted as ext4, skipping format."
fi

# === 3. Prepare mount point ===
mkdir -p /data

# === 4. Add to fstab if not present ===
fstab_entry="/dev/mmcblk0p8  /data  ext4  defaults,noatime  0  2"
if ! grep -q "/dev/mmcblk0p8.* /data" /etc/fstab; then
    echo "$fstab_entry" >> /etc/fstab
    echo "OK: Added /data to /etc/fstab"
else
    echo "INFO: /data already in /etc/fstab"
fi

# === 5. Mount /data ===
echo "Mounting /data..."
if mount /data; then
    echo "OK: /data mounted successfully."
else
    echo "ERROR: Failed to mount /data"
    exit 1
fi

# === 6. Online resize /data to full partition size ===
echo "Resizing /data filesystem to full capacity..."
if resize2fs "$data_part"; then
    echo "OK: /data resized to full partition size."
else
    echo "ERROR: resize2fs failed on $data_part"
    exit 1
fi

# === 7. Set permissions ===
chown -R ubuntu:ubuntu /data
chmod 755 /data
echo "OK: Set ownership and permissions on /data."

# === 8. Create user symlink ===
symlink="/home/ubuntu/data"
if [ ! -L "$symlink" ]; then
    ln -sf /data "$symlink"
    echo "OK: Created symlink $symlink -> /data"
else
    echo "INFO: Symlink $symlink already exists."
fi

# === 9. Mark completion (fallback for ConditionFirstBoot) ===
touch /root/.firstboot_done
echo "OK: First boot init completed successfully."

# === 10. Final log ===
echo "=== First Boot Init Completed at $(date) ==="