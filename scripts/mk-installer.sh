#!/bin/bash
set -euo pipefail

ARCH=""
BOOTLOADER=""
ROOTFS=""
KERNEL_DIR=""
NOS_NAME=""
NOS_VERSION=""
GIT_BRANCH=""
GIT_REV=""
PART_SIZE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --bootloader) BOOTLOADER="$2"; shift 2 ;;
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
        --nos-name) NOS_NAME="$2"; shift 2 ;;
        --nos-version) NOS_VERSION="$2"; shift 2 ;;
        --git-branch) GIT_BRANCH="$2"; shift 2 ;;
        --git-rev) GIT_REV="$2"; shift 2 ;;
        --part-size) PART_SIZE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

: "${ARCH:=x86_64}"
: "${BOOTLOADER:=grub}"
: "${NOS_NAME:=ONIECraft}"
: "${NOS_VERSION:=1.0.0}"
: "${GIT_BRANCH:=unknown}"
: "${GIT_REV:=unknown}"
: "${PART_SIZE:=4096}"
: "${KERNEL_DIR:=build/kernel}"

ROOTFS="$(readlink -f "${ROOTFS:-build/rootfs}")"
KERNEL_DIR="$(readlink -f "$KERNEL_DIR")"

if [[ -z "${OUTPUT:-}" ]]; then
    OUTPUT="build/${NOS_NAME}-${NOS_VERSION}-${ARCH}-installer.bin"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER_DIR="$(dirname "$SCRIPT_DIR")/installer"

if [[ ! -d "$ROOTFS" ]]; then
    echo "ERROR: Rootfs directory not found: $ROOTFS"
    exit 1
fi

KVER=""
if [[ -f "$KERNEL_DIR/.kernel_version" ]]; then
    KVER=$(cat "$KERNEL_DIR/.kernel_version")
else
    KVER=$(ls "$ROOTFS/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*vmlinuz-||')
fi

if [[ -z "$KVER" ]]; then
    echo "ERROR: Could not determine kernel version"
    exit 1
fi

echo "Packaging ONIE installer image..."
echo "  Kernel version: $KVER"
echo "  Architecture:   $ARCH"
echo "  Bootloader:     $BOOTLOADER"

VMLINUZ="$ROOTFS/boot/vmlinuz-$KVER"
INITRD="$ROOTFS/boot/initrd.img-$KVER"

if [[ ! -f "$VMLINUZ" ]]; then
    VMLINUZ="$KERNEL_DIR/vmlinuz"
fi
if [[ ! -f "$INITRD" ]]; then
    INITRD="$KERNEL_DIR/initrd.img"
fi

if [[ ! -f "$VMLINUZ" ]]; then
    echo "ERROR: Kernel image not found"
    exit 1
fi
if [[ ! -f "$INITRD" ]]; then
    echo "ERROR: Initramfs not found"
    exit 1
fi

echo "  Kernel: $VMLINUZ"
echo "  Initrd: $INITRD"

echo "Packaging rootfs into tar.gz archive..."

echo "Cleaning up rootfs before packaging..."
sudo rm -rf "$ROOTFS/packages/" 2>/dev/null || true
sudo rm -rf "$ROOTFS/var/cache/apt/archives/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/var/cache/apt/*.bin" 2>/dev/null || true
sudo rm -rf "$ROOTFS/var/lib/apt/lists/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/doc/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/locale/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/man/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/info/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/lintian/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/common-licenses/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/pixmaps/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/include/"* 2>/dev/null || true
# NOTE: Do NOT remove /usr/lib/cargo/ - it contains Rust coreutils binaries
# that /usr/bin/ symlinks (ls, cp, mv, mkdir, etc.) depend on
sudo rm -rf "$ROOTFS/usr/share/bug/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/linda/"* 2>/dev/null || true
sudo rm -rf "$ROOTFS/usr/share/doc-base/"* 2>/dev/null || true
sudo find "$ROOTFS" -ignore_readdir_race -name "*.pyc" -delete 2>/dev/null || true
sudo find "$ROOTFS" -ignore_readdir_race -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
sudo find "$ROOTFS" -ignore_readdir_race -name "*.a" -not -path "*/lib/modules/*" -delete 2>/dev/null || true
sudo find "$ROOTFS" -ignore_readdir_race -name "*.la" -delete 2>/dev/null || true
sudo find "$ROOTFS/usr/share/locale" -ignore_readdir_race -mindepth 1 -maxdepth 1 -not -name "en_US" -not -name "C" -exec rm -rf {} + 2>/dev/null || true
sudo find "$ROOTFS/usr/lib/locale" -ignore_readdir_race -mindepth 1 -maxdepth 1 -not -name "en_US" -not -name "C" -exec rm -rf {} + 2>/dev/null || true

echo "Removing unnecessary firmware..."
# Aggressive firmware pruning for network switch appliance
# Keep: CPU microcode (amd64-microcode, intel-microcode), virtio, minimal net/storage
FW_DIRS="nvidia qcom amdgpu i915 mediatek ath11k ath10k ath12k ath6k ath9k intel-ucode intel radeon amd-ucode amd amdnpu dpaa2 meson rockchip sunxi tegra vsc cypress imx ti-connectivity ti rtl_bt rtl_nic rtlwifi rtw88 rtw89 brcm qca adsl dvb siano ev56 go7007 cxgb4 usbdux snd 3com kaweth edgeport emi26 emi62 tigon ess sun yamaha acenic cirrus ezusb sb16 ositech vxworks keyspan_pda keyspan e100 dabusb av7110 ttusb-budget ihex2fw phanfw.bin ct2fw.bin ctfw.bin lcs.fw netronome mrvl mellanox qed xe liquidio asihpi LENOVO bnx2x amlogic ueagle-atm libertas airoha amphion cnm ea rsi mwl8k atmel dell nxp wfx"
for d in $FW_DIRS; do
    sudo rm -rf "$ROOTFS/lib/firmware/$d" "$ROOTFS/usr/lib/firmware/$d" 2>/dev/null || true
done

echo "Optimizing kernel modules..."
if [[ -d "$ROOTFS/lib/modules" ]]; then
    # Remove unnecessary kernel modules for network switch appliance
    MODULES_DIR="$ROOTFS/lib/modules"
    KMOD_DIRS="sound drivers/media drivers/gpu drivers/drm drivers/infiniband drivers/staging"
    for d in $KMOD_DIRS; do
        sudo rm -rf "$MODULES_DIR/"*/kernel/$d 2>/dev/null || true
    done
    # Re-compress and strip remaining modules
    sudo find "$MODULES_DIR" -ignore_readdir_race -type f -name "*.ko.zst" 2>/dev/null | while read ko; do
        sudo zstd -d "$ko" -o "${ko%.zst}.ko" --rm 2>/dev/null && \
        sudo strip --strip-unneeded "${ko%.zst}.ko" && \
        sudo zstd -19 -q "${ko%.zst}.ko" -o "$ko" --rm 2>/dev/null || true
    done
fi

echo "Stripping binaries..."
sudo find "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin" "$ROOTFS/usr/lib/x86_64-linux-gnu" \
    -ignore_readdir_race -type f -executable -not -name "*.sh" -not -name "*.py" 2>/dev/null | while read f; do
    sudo strip --strip-unneeded "$f" 2>/dev/null || true
done

# Update shared library cache and kernel module dependencies after modifications
echo "Updating ldconfig and depmod..."
sudo chroot "$ROOTFS" ldconfig 2>/dev/null || true
sudo chroot "$ROOTFS" depmod -a 2>/dev/null || true

TMP_DIR=$(mktemp -d)
trap 'rm -rf $TMP_DIR' EXIT

echo "Creating tar.gz rootfs (excluding boot/)..."
sudo tar --xattrs --xattrs-include='*' -czf "$TMP_DIR/fs.tar.gz" -C "$ROOTFS" --exclude='./boot' --exclude='./packages' --exclude='./var/cache/apt' --exclude='./var/lib/apt/lists' --exclude='./usr/share/doc' --exclude='./usr/share/man' --exclude='./usr/share/info' --exclude='./usr/share/locale' --exclude='./usr/include' .

INSTALLER_TMP="$TMP_DIR/installer"
mkdir -p "$INSTALLER_TMP"

sudo cp "$VMLINUZ" "$INSTALLER_TMP/demo.vmlinuz"
sudo cp "$INITRD" "$INSTALLER_TMP/demo.initrd"
sudo chmod a+r "$INSTALLER_TMP/demo.vmlinuz" "$INSTALLER_TMP/demo.initrd"

cp "$TMP_DIR/fs.tar.gz" "$INSTALLER_TMP/fs.tar.gz"

if [[ "$BOOTLOADER" == "grub" ]]; then
    INSTALL_ARCH_DIR="$INSTALLER_DIR/grub-arch"
else
    INSTALL_ARCH_DIR="$INSTALLER_DIR/u-boot-arch"
fi

cp "$SCRIPT_DIR/../files/install.sh" "$INSTALLER_TMP/install.sh"

if [[ -d "$INSTALL_ARCH_DIR" ]]; then
    for f in "$INSTALL_ARCH_DIR/"*; do
        if [[ "$(basename "$f")" != "install.sh" ]]; then
            cp -r "$f" "$INSTALLER_TMP/"
        fi
    done
fi

cat > "$INSTALLER_TMP/machine.conf" <<EOF
machine=$NOS_NAME
platform=$NOS_NAME-$ARCH
nos_name=$NOS_NAME
nos_version=$NOS_VERSION
nos_arch=$ARCH
git_branch=$GIT_BRANCH
git_rev=$GIT_REV
part_size=$PART_SIZE
EOF

sed -i -e "s/%%DEMO_TYPE%%/OS/g" "$INSTALLER_TMP/install.sh"
chmod +x "$INSTALLER_TMP/install.sh"

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
if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER:$SUDO_USER" "$OUTPUT" 2>/dev/null || true
fi

echo ""
echo "Success: ONIE installer image created:"
ls -lh "$OUTPUT"
