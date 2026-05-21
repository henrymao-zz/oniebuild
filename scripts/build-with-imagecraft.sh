#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ARCH=""
BOOTLOADER=""
NOS_NAME=""
NOS_VERSION=""
PART_SIZE=""
OUTPUT=""
KERNEL_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --bootloader) BOOTLOADER="$2"; shift 2 ;;
        --nos-name) NOS_NAME="$2"; shift 2 ;;
        --nos-version) NOS_VERSION="$2"; shift 2 ;;
        --part-size) PART_SIZE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

: "${ARCH:=x86_64}"
: "${BOOTLOADER:=grub}"
: "${NOS_NAME:=Ubuntu}"
: "${NOS_VERSION:=1.0.0}"
: "${PART_SIZE:=4096}"
: "${KERNEL_DIR:=build/kernel}"

if [[ -z "${OUTPUT:-}" ]]; then
    OUTPUT="build/${NOS_NAME}-${NOS_VERSION}-${ARCH}-installer.bin"
fi

echo "Building NOS image with imagecraft..."
echo "  Architecture:  $ARCH"
echo "  Bootloader:    $BOOTLOADER"
echo "  NOS Name:      $NOS_NAME"
echo "  NOS Version:   $NOS_VERSION"

command -v imagecraft >/dev/null 2>&1 || {
    echo "ERROR: imagecraft not found. Install with: sudo snap install imagecraft --channel=beta --classic"
    exit 1
}

BUILD_DIR="$PROJECT_DIR/build"
mkdir -p "$BUILD_DIR"

IMAGECRAFT_DIR="$BUILD_DIR/imagecraft"
mkdir -p "$IMAGECRAFT_DIR"

echo "Running imagecraft pack --destructive-mode..."
imagecraft pack --destructive-mode 2>&1 || {
    echo "ERROR: imagecraft pack failed"
    exit 1
}

DISK_IMG="$PROJECT_DIR/pc.img"
if [[ ! -f "$DISK_IMG" ]]; then
    echo "ERROR: imagecraft output not found: $DISK_IMG"
    exit 1
fi

echo "Extracting rootfs from imagecraft disk image..."

ROOTFS_DIR="$BUILD_DIR/rootfs"
MOUNT_DIR="$BUILD_DIR/rootfs-mount"
if [[ -d "$MOUNT_DIR" ]]; then
    sudo rm -rf "$MOUNT_DIR"
fi
sudo mkdir -p "$MOUNT_DIR"

LOOP_DEV=$(sudo losetup --show -fP "$DISK_IMG")
trap 'sudo losetup -d $LOOP_DEV 2>/dev/null || true' EXIT

ROOTFS_PART="${LOOP_DEV}p1"
if [[ ! -b "$ROOTFS_PART" ]]; then
    ROOTFS_PART="${LOOP_DEV}p2"
fi
if [[ ! -b "$ROOTFS_PART" ]]; then
    echo "ERROR: Could not find rootfs partition in $DISK_IMG"
    sudo partprobe "$LOOP_DEV" 2>/dev/null || true
    sleep 2
    ROOTFS_PART="${LOOP_DEV}p1"
    if [[ ! -b "$ROOTFS_PART" ]]; then
        ROOTFS_PART="${LOOP_DEV}p2"
    fi
fi

sudo mount -t ext4 -o ro "$ROOTFS_PART" "$MOUNT_DIR"

TMP_ROOTFS="$BUILD_DIR/rootfs-extracted"
if [[ -d "$TMP_ROOTFS" ]]; then
    sudo rm -rf "$TMP_ROOTFS"
fi
sudo mkdir -p "$TMP_ROOTFS"

echo "Copying rootfs contents..."
sudo cp -a "$MOUNT_DIR/." "$TMP_ROOTFS/"

sudo umount "$MOUNT_DIR" 2>/dev/null || true
sudo rmdir "$MOUNT_DIR" 2>/dev/null || true
sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
trap - EXIT

if [[ -d "$ROOTFS_DIR" ]]; then
    sudo rm -rf "$ROOTFS_DIR"
fi
sudo mv "$TMP_ROOTFS" "$ROOTFS_DIR"

rm -f "$DISK_IMG"

echo "Rootfs extracted to: $ROOTFS_DIR"

KVER=""
if [[ -f "$KERNEL_DIR/.kernel_version" ]]; then
    KVER=$(cat "$KERNEL_DIR/.kernel_version")
else
    KVER=$(ls "$ROOTFS_DIR/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*vmlinuz-||')
fi

if [[ -z "$KVER" ]]; then
    echo "ERROR: Could not determine kernel version"
    exit 1
fi

echo "  Kernel version: $KVER"

VMLINUX="$ROOTFS_DIR/boot/vmlinuz-$KVER"
INITRD="$ROOTFS_DIR/boot/initrd.img-$KVER"

if [[ ! -f "$VMLINUX" ]]; then
    VMLINUZ="$KERNEL_DIR/vmlinuz"
fi
if [[ ! -f "$INITRD" ]]; then
    INITRD="$KERNEL_DIR/initrd.img"
fi

if [[ ! -f "$VMLINUX" ]] || [[ ! -f "$INITRD" ]]; then
    echo "ERROR: Kernel or initrd not found"
    exit 1
fi

echo "Packaging ONIE installer..."

command -v mksquashfs >/dev/null 2>&1 || {
    echo "ERROR: mksquashfs not found. Install: sudo apt install squashfs-tools"
    exit 1
}

echo "Creating squashfs rootfs (excluding boot/)..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf $TMP_DIR' EXIT

sudo mksquashfs "$ROOTFS_DIR" "$TMP_DIR/fs.squashfs" -comp xz -b 1M -e boot -e var/cache/apt -e var/lib/apt/lists -no-progress -no-exports -no-xattrs

INSTALLER_TMP="$TMP_DIR/installer"
mkdir -p "$INSTALLER_TMP"

sudo cp "$VMLINUX" "$INSTALLER_TMP/demo.vmlinuz"
sudo cp "$INITRD" "$INSTALLER_TMP/demo.initrd"
sudo chmod a+r "$INSTALLER_TMP/demo.vmlinuz" "$INSTALLER_TMP/demo.initrd"

cp "$TMP_DIR/fs.squashfs" "$INSTALLER_TMP/fs.squashfs"

INSTALLER_DIR="$PROJECT_DIR/installer"
if [[ "$BOOTLOADER" == "grub" ]]; then
    INSTALL_ARCH_DIR="$INSTALLER_DIR/grub-arch"
else
    INSTALL_ARCH_DIR="$INSTALLER_DIR/u-boot-arch"
fi

if [[ -d "$INSTALL_ARCH_DIR" ]]; then
    cp -r "$INSTALL_ARCH_DIR/"* "$INSTALLER_TMP/"
else
    echo "ERROR: Installer arch directory not found: $INSTALL_ARCH_DIR"
    exit 1
fi

cat > "$INSTALLER_TMP/machine.conf" <<EOF
machine=$NOS_NAME
platform=$NOS_NAME-$ARCH
nos_name=$NOS_NAME
nos_version=$NOS_VERSION
nos_arch=$ARCH
part_size=$PART_SIZE
EOF

if [[ -f "$INSTALLER_TMP/install.sh" ]]; then
    sed -i -e "s/%%DEMO_TYPE%%/OS/g" "$INSTALLER_TMP/install.sh"
    chmod +x "$INSTALLER_TMP/install.sh"
fi

SHARCH="$TMP_DIR/sharch.tar"
tar -C "$TMP_DIR" -cf "$SHARCH" installer || {
    echo "ERROR: Failed to create installer archive"
    exit 1
}

SHA1=$(sha1sum "$SHARCH" | awk '{print $1}')

SHARCH_BODY="$INSTALLER_DIR/sharch_body.sh"
if [[ ! -f "$SHARCH_BODY" ]]; then
    echo "ERROR: sharch_body.sh template not found: $SHARCH_BODY"
    exit 1
fi

OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"

cp "$SHARCH_BODY" "$OUTPUT"
sed -i -e "s/%%IMAGE_SHA1%%/$SHA1/" "$OUTPUT"
cat "$SHARCH" >> "$OUTPUT"
chmod +x "$OUTPUT"

echo ""
echo "Success: ONIE installer image created:"
ls -lh "$OUTPUT"
