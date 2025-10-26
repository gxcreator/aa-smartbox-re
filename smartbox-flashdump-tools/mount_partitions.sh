#!/bin/bash

# mount_all_partitions.sh - Mount all partitions from SPI NOR flash dump

MOUNT_BASE="/mnt/extracted_flash"
EXTRACT_DIR="extracted_partitions"

# Partition definitions
declare -A PARTITIONS
PARTITIONS[uboot]="0x000000000000 0x000000060000"
PARTITIONS[boot]="0x000000060000 0x000000240000"
PARTITIONS[rootfs]="0x0000002a0000 0x000000490000"
PARTITIONS[rootfs_data]="0x000000730000 0x000000080000"
PARTITIONS[env]="0x0000007b0000 0x000000020000"
PARTITIONS[private]="0x0000007d0000 0x000000010000"
PARTITIONS[app]="0x0000007e0000 0x0000006c0000"
PARTITIONS[udisk]="0x000000ea0000 0x000000160000"

# Function to try mounting a partition
mount_partition() {
    local DUMP="$1"
    local name="$2"
    local offset="$3"
    local size="$4"
    local partition_file="$EXTRACT_DIR/${name}.bin"
    local mount_point="$MOUNT_BASE/$name"

    echo ""
    echo "=========================================="
    echo "Processing: $name"
    echo "=========================================="

    # Extract partition
    echo "Extracting $name..."
    dd if="$DUMP" of="$partition_file" bs=1 skip=$((offset)) count=$((size)) 2>/dev/null

    # Check type
    echo "Filesystem type:"
    file "$partition_file"

    # Create mount point
    sudo mkdir -p "$mount_point"

    # Try SquashFS
    if sudo mount -t squashfs -o loop,ro "$partition_file" "$mount_point" 2>/dev/null; then
        echo "[DONE] Mounted as SquashFS (read-only) at $mount_point"
        ls -lh "$mount_point" | head -10
        return 0
    fi

    # Try VFAT
    if sudo mount -t vfat -o loop,rw "$partition_file" "$mount_point" 2>/dev/null; then
        echo "[DONE] Mounted as VFAT at $mount_point"
        ls -lh "$mount_point" | head -10
        return 0
    fi

    # Try ext4
    if sudo mount -t ext4 -o loop,rw "$partition_file" "$mount_point" 2>/dev/null; then
        echo "[DONE] Mounted as ext4 at $mount_point"
        ls -lh "$mount_point" | head -10
        return 0
    fi

    # Try JFFS2 (needs MTD)
    LOOP=$(sudo losetup -f --show "$partition_file" 2>/dev/null)
    if [ -n "$LOOP" ]; then
        echo "Creating MTD device from $LOOP..."
        sudo sh -c "echo '$LOOP,65536' > /sys/module/block2mtd/parameters/block2mtd" 2>/dev/null
        sleep 1

        echo "Checking /proc/mtd..."
        cat /proc/mtd | grep "$(basename "$LOOP")"

        MTD=$(cat /proc/mtd | grep "$(basename "$LOOP")" | cut -d: -f1)
        echo "Found MTD device: $MTD"

        if [ -n "$MTD" ]; then
            echo "Attempting to mount /dev/mtdblock${MTD#mtd} as JFFS2..."
            if sudo mount -t jffs2 "/dev/mtdblock${MTD#mtd}" "$mount_point" 2>/dev/null; then
                echo "[DONE] Mounted as JFFS2 at $mount_point"
                ls -lh "$mount_point" | head -10
                return 0
            fi
        fi
    fi

    echo "[ERROR] Could not mount $name (may be raw data or unsupported filesystem)"
    sudo rmdir "$mount_point" 2>/dev/null
    return 1
}

# Function to mount a single partition
mount_single_partition() {
    local DUMP="$1"
    local PARTITION_NAME="$2"

    # Check if dump exists
    if [ ! -f "$DUMP" ]; then
        echo "Error: $DUMP not found!"
        exit 1
    fi

    # Check if partition exists
    if [ -z "${PARTITIONS[$PARTITION_NAME]}" ]; then
        echo "Error: Unknown partition '$PARTITION_NAME'"
        echo "Available partitions: ${!PARTITIONS[@]}"
        exit 1
    fi

    # Create extraction directory
    mkdir -p "$EXTRACT_DIR"

    # Load MTD modules
    echo "Loading MTD modules..."
    sudo modprobe mtdblock 2>/dev/null
    sudo modprobe block2mtd 2>/dev/null

    # Create base mount directory
    sudo mkdir -p "$MOUNT_BASE"

    # Parse partition offset and size
    read -r offset size <<< "${PARTITIONS[$PARTITION_NAME]}"

    # Mount the partition
    mount_partition "$DUMP" "$PARTITION_NAME" "$offset" "$size"
}

# Function to mount all partitions
mount_all() {
    local DUMP="$1"

    # Check if dump exists
    if [ ! -f "$DUMP" ]; then
        echo "Error: $DUMP not found!"
        exit 1
    fi

    # Create extraction directory
    mkdir -p "$EXTRACT_DIR"

    # Load MTD modules
    echo "Loading MTD modules..."
    sudo modprobe mtdblock 2>/dev/null
    sudo modprobe block2mtd 2>/dev/null

    # Create base mount directory
    sudo mkdir -p "$MOUNT_BASE"

    # Mount all partitions from the PARTITIONS array
    # Order: uboot, boot, rootfs, rootfs_data, env, private, app, udisk
    for part_name in uboot boot rootfs rootfs_data env private app udisk; do
        if [ -n "${PARTITIONS[$part_name]}" ]; then
            read -r offset size <<< "${PARTITIONS[$part_name]}"
            mount_partition "$DUMP" "$part_name" "$offset" "$size"
        fi
    done

    # Summary
    echo ""
    echo "=========================================="
    echo " Mounted Partitions:"
    echo "=========================================="
    mount | grep "$MOUNT_BASE"

    echo ""
    echo "To unmount all:"
    echo "  $0 unmount"
}

# Function to unmount all partitions
unmount_all() {
    echo "Unmounting all partitions..."
    
    # Unmount all mounted partitions
    for mount_point in $MOUNT_BASE/*; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            echo "Unmounting $mount_point..."
            sudo umount "$mount_point" 2>/dev/null
        fi
        sudo rmdir "$mount_point" 2>/dev/null
    done
    
    # Clean up loop devices
    echo "Cleaning up loop devices..."
    sudo losetup -D
    
    # Remove MTD devices (by removing block2mtd module)
    echo "Removing MTD devices..."
    sudo modprobe -r block2mtd 2>/dev/null
    sudo modprobe -r mtdblock 2>/dev/null
    
    # Clean up extracted partition files
    echo "Cleaning up partition files..."
    rm -rf "$EXTRACT_DIR" 2>/dev/null
    
    echo "[DONE] Cleanup complete"
    exit 0
}

# Function to write partition back to dump
write_partition() {
    local DUMP="$1"
    local PARTITION_NAME="$2"
    
    # Check if dump exists
    if [ ! -f "$DUMP" ]; then
        echo "Error: $DUMP not found!"
        exit 1
    fi
    
    # Check if partition exists in definitions
    if [ -z "${PARTITIONS[$PARTITION_NAME]}" ]; then
        echo "Error: Unknown partition '$PARTITION_NAME'"
        echo "Available partitions: ${!PARTITIONS[@]}"
        exit 1
    fi
    
    # Check if extracted partition file exists
    local partition_file="$EXTRACT_DIR/${PARTITION_NAME}.bin"
    if [ ! -f "$partition_file" ]; then
        echo "Error: Partition file $partition_file not found!"
        echo "You need to extract/mount the partition first"
        exit 1
    fi
    
    # Parse partition offset and size
    read -r offset size <<< "${PARTITIONS[$PARTITION_NAME]}"
    
    # Get actual file size
    local actual_size=$(stat -c%s "$partition_file")
    
    echo "=========================================="
    echo "Writing partition: $PARTITION_NAME"
    echo "=========================================="
    echo "Source file: $partition_file"
    echo "Target dump: $DUMP"
    echo "Offset: $offset"
    echo "Max size: $size ($(($size)) bytes)"
    echo "Actual size: $actual_size bytes"
    echo ""
    
    # Check if partition fits
    if [ $actual_size -gt $(($size)) ]; then
        echo "ERROR: Partition file ($actual_size bytes) exceeds maximum size ($(($size)) bytes)"
        echo "Cannot write - would overflow into next partition!"
        exit 1
    fi
    
    # Create backup
    local backup_file="${DUMP}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "Creating backup: $backup_file"
    cp "$DUMP" "$backup_file"
    
    # Write partition back to dump
    echo "Writing partition data to dump at offset $offset..."
    dd if="$partition_file" of="$DUMP" bs=1 seek=$(($offset)) conv=notrunc 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "[OK] Successfully wrote $PARTITION_NAME back to $DUMP"
        echo "[OK] Backup saved as: $backup_file"
    else
        echo "[ERROR] Error writing partition!"
        exit 1
    fi
}

# Check for command argument
if [ -z "$1" ]; then
    echo "Usage: $0 <mount|unmount|write> <flash_dump.bin> [partition]"
    echo ""
    echo "Commands:"
    echo "  mount <dump> [partition]  - Mount all partitions or a specific one"
    echo "  unmount                   - Unmount all and cleanup"
    echo "  write <dump> <partition>  - Write modified partition back to dump"
    echo ""
    echo "Available partitions: ${!PARTITIONS[@]}"
    echo ""
    echo "Examples:"
    echo "  $0 mount flash_dump.bin              # Mount all partitions"
    echo "  $0 mount flash_dump.bin rootfs       # Mount only rootfs partition"
    echo "  $0 write flash_dump.bin rootfs       # Write rootfs back to dump"
    echo "  $0 unmount                           # Unmount all and cleanup"
    exit 1
fi

COMMAND="$1"

# Check if unmount command is specified
if [ "$COMMAND" == "unmount" ] || [ "$COMMAND" == "umount" ]; then
    unmount_all
fi

# Check if mount command is specified
if [ "$COMMAND" == "mount" ]; then
    shift  # Remove "mount" from arguments
    DUMP="$1"
    PART="$2"

    # Check if dump file argument is provided
    if [ -z "$DUMP" ]; then
        echo "Error: Please specify flash dump file"
        echo "Usage: $0 mount <flash_dump.bin> [partition]"
        echo ""
        echo "Available partitions: ${!PARTITIONS[@]}"
        exit 1
    fi

    if [ -n "$PART" ]; then
        echo "Mounting single partition: $PART"
        mount_single_partition "$DUMP" "$PART"
    else
        echo "Mounting all partitions from $DUMP"
        mount_all "$DUMP"
    fi
elif [ "$COMMAND" == "write" ]; then
    shift  # Remove "write" from arguments
    DUMP="$1"
    PART="$2"
    
    # Check if dump file argument is provided
    if [ -z "$DUMP" ]; then
        echo "Error: Please specify flash dump file"
        echo "Usage: $0 write <flash_dump.bin> <partition>"
        exit 1
    fi
    
    # Check if partition argument is provided
    if [ -z "$PART" ]; then
        echo "Error: Please specify partition to write"
        echo "Usage: $0 write <flash_dump.bin> <partition>"
        echo "Available partitions: ${!PARTITIONS[@]}"
        exit 1
    fi
    
    write_partition "$DUMP" "$PART"
else
    echo "Error: Unknown command '$COMMAND'"
    echo "Usage: $0 <mount|unmount|write> <flash_dump.bin> [partition]"
    echo "Run '$0' without arguments for detailed help"
    exit 1
fi
