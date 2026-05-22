#!/bin/bash
set -euo pipefail

ARCH=""
BOOTLOADER=""
ROOTFS=""
KERNEL_DIR=""
NOS_NAME=""
NOS_VERSION=""
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
        --part-size) PART_SIZE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

: "${ARCH:=x86_64}"
: "${BOOTLOADER:=grub}"
: "${NOS_NAME:=ONIECraft}"
: "${NOS_VERSION:=1.0.0}"
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

command -v mksquashfs >/dev/null 2>&1 || {
    echo "ERROR: mksquashfs not found. Install: sudo apt install squashfs-tools"
    exit 1
}

echo "Cleaning up rootfs before packaging..."
sudo rm -rf "$ROOTFS/packages/"
sudo rm -rf "$ROOTFS/var/cache/apt/archives/"*
sudo rm -rf "$ROOTFS/var/cache/apt/*.bin"
sudo rm -rf "$ROOTFS/var/lib/apt/lists/"*
sudo rm -rf "$ROOTFS/usr/share/doc/"*
sudo rm -rf "$ROOTFS/usr/share/locale/"*
sudo rm -rf "$ROOTFS/usr/share/man/"*
sudo rm -rf "$ROOTFS/usr/share/info/"*
sudo rm -rf "$ROOTFS/usr/share/lintian/"*
sudo rm -rf "$ROOTFS/usr/share/common-licenses/"*
sudo rm -rf "$ROOTFS/usr/share/pixmaps/"*
sudo rm -rf "$ROOTFS/usr/include/"*
sudo rm -rf "$ROOTFS/usr/share/bug/"*
sudo rm -rf "$ROOTFS/usr/share/linda/"*
sudo rm -rf "$ROOTFS/usr/share/doc-base/"*
sudo find "$ROOTFS" -name "*.pyc" -delete
sudo find "$ROOTFS" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
sudo find "$ROOTFS" -name "*.a" -not -path "*/lib/modules/*" -delete
sudo find "$ROOTFS" -name "*.la" -delete
sudo find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 -not -name "en_US" -not -name "C" -exec rm -rf {} + 2>/dev/null || true
sudo find "$ROOTFS/usr/lib/locale" -mindepth 1 -maxdepth 1 -not -name "en_US" -not -name "C" -exec rm -rf {} + 2>/dev/null || true

echo "Removing unnecessary firmware..."
FW_DIRS="nvidia qcom amdgpu i915 mediatek ath11k ath10k ath12k ath6k ath9k intel-ucode radeon amd-ucode dpaa2 meson rockchip sunxi tegra vsc cypress imx ti-connectivity rtl_bt rtl_nic rtlwifi rtw88 rtw89 brcm qca adsl dvb siano ev56 go7007 cxgb4 usbdux snd 3com kaweth edgeport emi26 emi62 tigon ess sun yamaha acenic cirrus ezusb sb16 ositech vxworks keyspan_pda keyspan e100 dabusb av7110 ttusb-budget ihex2fw phanfw.bin ct2fw.bin ctfw.bin lcs.fw netronome mrvl mellanox qed xe"
for d in $FW_DIRS; do
    sudo rm -rf "$ROOTFS/lib/firmware/$d" "$ROOTFS/usr/lib/firmware/$d" 2>/dev/null || true
done

echo "Optimizing kernel modules..."
if [[ -d "$ROOTFS/lib/modules" ]]; then
    sudo find "$ROOTFS/lib/modules" -type f -name "*.ko.zst" | while read ko; do
        sudo zstd -d "$ko" -o "${ko%.zst}.ko" --rm 2>/dev/null && \
        sudo strip --strip-unneeded "${ko%.zst}.ko" && \
        sudo zstd -19 -q "${ko%.zst}.ko" -o "$ko" --rm 2>/dev/null || true
    done
fi

echo "Stripping binaries..."
sudo find "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin" "$ROOTFS/usr/lib/x86_64-linux-gnu" \
    -type f -executable -not -name "*.sh" -not -name "*.py" 2>/dev/null | while read f; do
    sudo strip --strip-all "$f" 2>/dev/null || sudo strip --strip-unneeded "$f" 2>/dev/null || true
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf $TMP_DIR' EXIT

echo "Creating squashfs rootfs (excluding boot/)..."
sudo mksquashfs "$ROOTFS" "$TMP_DIR/fs.squashfs" -comp xz -b 1M -e boot -e packages -e var/cache/apt -e var/lib/apt/lists -e usr/share/doc -e usr/share/man -e usr/share/info -e usr/share/locale -e usr/include -no-progress -no-exports -no-xattrs

INSTALLER_TMP="$TMP_DIR/installer"
mkdir -p "$INSTALLER_TMP"

sudo cp "$VMLINUZ" "$INSTALLER_TMP/demo.vmlinuz"
sudo cp "$INITRD" "$INSTALLER_TMP/demo.initrd"
sudo chmod a+r "$INSTALLER_TMP/demo.vmlinuz" "$INSTALLER_TMP/demo.initrd"

cp "$TMP_DIR/fs.squashfs" "$INSTALLER_TMP/fs.squashfs"

if [[ "$BOOTLOADER" == "grub" ]]; then
    INSTALL_ARCH_DIR="$INSTALLER_DIR/grub-arch"
else
    INSTALL_ARCH_DIR="$INSTALLER_DIR/u-boot-arch"
fi

if [[ -d "$INSTALL_ARCH_DIR" ]]; then
    cp -r "$INSTALL_ARCH_DIR/"* "$INSTALLER_TMP/"
else
    echo "WARNING: Installer arch directory not found: $INSTALL_ARCH_DIR"
    echo "Creating minimal install.sh"
    cat > "$INSTALLER_TMP/install.sh" <<'INSTALL_EOF'
#!/bin/sh
set -e

cd $(dirname $0)
. ./machine.conf

echo "Installer: platform=$platform"

blk_dev=$(blkid | grep ONIE-BOOT | awk '{print $1}' | sed -e 's/[1-9][0-9]*:.*$//' | sed -e 's/\([0-9]\)\(p\)/\1/' | head -n 1)
[ -b "$blk_dev" ] || { echo "Error: Unable to find ONIE block device"; exit 1; }

PART_SIZE=${PART_SIZE:-4096}
demo_volume_label="ONIE-DEMO-OS"

if [ -d "/sys/firmware/efi/efivars" ]; then
    firmware="uefi"
else
    firmware="bios"
fi

onie_partition_type=$(onie-sysinfo -t)

if [ "$onie_partition_type" = "gpt" ]; then
    demo_part=$(sgdisk -p $blk_dev | grep "$demo_volume_label" | awk '{print $1}')
    if [ -n "$demo_part" ]; then
        sgdisk -d $demo_part $blk_dev || exit 1
        partprobe
    fi
    last_part=$(sgdisk -p $blk_dev | tail -n 1 | awk '{print $1}')
    demo_part=$((last_part + 1))
    blk_suffix=
    echo ${blk_dev} | grep -q mmcblk && blk_suffix="p"
    echo ${blk_dev} | grep -q nvme && blk_suffix="p"
    sgdisk --new=${demo_part}::+${PART_SIZE}MB \
        --change-name=${demo_part}:$demo_volume_label $blk_dev || exit 1
    partprobe
elif [ "$onie_partition_type" = "msdos" ]; then
    part_info="$(blkid | grep $demo_volume_label | awk -F: '{print $1}')"
    if [ -n "$part_info" ]; then
        demo_part="$(echo -n $part_info | sed -e s#${blk_dev}##)"
        parted -s $blk_dev rm $demo_part || exit 1
        partprobe
    fi
    last_part_info="$(parted -s -m $blk_dev unit s print | tail -n 1)"
    last_part_num="$(echo -n $last_part_info | awk -F: '{print $1}')"
    last_part_end="$(echo -n $last_part_info | awk -F: '{print $3}')"
    last_part_end=${last_part_end%s}
    demo_part=$((last_part_num + 1))
    demo_part_start=$((last_part_end + 1))
    sectors_per_mb=2048
    demo_part_end=$((demo_part_start + (PART_SIZE * sectors_per_mb) - 1))
    parted -s --align optimal $blk_dev unit s \
        mkpart primary $demo_part_start $demo_part_end set $demo_part boot on || exit 1
    partprobe
fi

demo_dev=$(echo $blk_dev | sed -e 's/\(mmcblk[0-9]\)/\1p/')$demo_part
echo $blk_dev | grep -q nvme && {
    demo_dev=$(echo $blk_dev | sed -e 's/\(nvme[0-9]n[0-9]\)/\1p/')$demo_part
}
partprobe

mkfs.ext4 -F -L $demo_volume_label $demo_dev || exit 1

demo_mnt=$(mktemp -d) || exit 1
mount -t ext4 -o defaults,rw $demo_dev $demo_mnt || exit 1

mkdir -p $demo_mnt/boot
cp boot/vmlinuz boot/initrd.img $demo_mnt/boot/

cp fs.squashfs $demo_mnt/

cat > $demo_mnt/install-rootfs.sh <<'ROOTFS_EOF'
#!/bin/sh
set -e

demo_mnt="$1"

echo "Installing squashfs rootfs..."
mkdir -p /tmp/rootfs_squash
mount -t squashfs -o ro "$demo_mnt/fs.squashfs" /tmp/rootfs_squash

mkdir -p /tmp/rootfs_overlay /tmp/rootfs_merged
mount -t overlay overlay -o lowerdir=/tmp/rootfs_squash,upperdir=/tmp/rootfs_overlay/rw,workdir=/tmp/rootfs_overlay/work /tmp/rootfs_merged

echo "Copying rootfs to target..."
cd /tmp/rootfs_merged
cp -a . "$demo_mnt/"

umount /tmp/rootfs_merged
umount /tmp/rootfs_squash
rm -rf /tmp/rootfs_squash /tmp/rootfs_overlay /tmp/rootfs_merged

rm -f "$demo_mnt/fs.squashfs" "$demo_mnt/install-rootfs.sh"
ROOTFS_EOF
chmod +x $demo_mnt/install-rootfs.sh

if [ "$firmware" = "uefi" ]; then
    echo "Configuring UEFI boot..."
    if [ -x /usr/sbin/grub-install ]; then
        grub-install --no-nvram \
            --bootloader-id="$demo_volume_label" \
            --efi-directory="/boot/efi" \
            --boot-directory="$demo_mnt" \
            --recheck "$blk_dev" 2>/dev/null || true
    fi

    for b in $(efibootmgr | grep "$demo_volume_label" | awk '{ print $1 }'); do
        num=${b#Boot}
        num=${num%\*}
        efibootmgr -b $num -B > /dev/null 2>&1
    done
    efibootmgr --quiet --create \
        --label "$demo_volume_label" \
        --disk $blk_dev --part $demo_part \
        --loader "/EFI/$demo_volume_label/grubx64.efi" 2>/dev/null || true
else
    echo "Configuring BIOS boot..."
    if [ -x /usr/sbin/grub-install ]; then
        grub-install --target=i386-pc \
            --boot-directory="$demo_mnt" \
            --recheck "$blk_dev" 2>/dev/null || true
    fi
fi

echo "Creating GRUB configuration..."
grub_cfg=$(mktemp)
[ -r /etc/machine.conf ] && . /etc/machine.conf
[ -r $demo_mnt/../onie/grub/grub-variables ] && . $demo_mnt/../onie/grub/grub-variables 2>/dev/null || true

GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:-console=tty0 console=ttyS0,115200n8}"

cat <<EOF > $grub_cfg
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input serial
terminal_output serial

set timeout=5

if [ -s \$prefix/grubenv ]; then
  load_env
fi
if [ "\${next_entry}" ] ; then
   set default="\${next_entry}"
   set next_entry=
   save_env next_entry
fi

menuentry '$demo_volume_label' --unrestricted {
        search --no-floppy --label --set=root $demo_volume_label
        echo    'Loading kernel ...'
        linux   /boot/vmlinuz $GRUB_CMDLINE_LINUX DEMO_TYPE=OS
        echo    'Loading initial ramdisk ...'
        initrd  /boot/initrd.img
}

EOF

if [ -x $demo_mnt/../onie/grub.d/50_onie_grub ]; then
    $demo_mnt/../onie/grub.d/50_onie_grub >> $grub_cfg 2>/dev/null || true
fi

mkdir -p $demo_mnt/grub
cp $grub_cfg $demo_mnt/grub/grub.cfg
rm -f $grub_cfg

onie-support $demo_mnt 2>/dev/null || true

umount $demo_mnt || true

if [ -x /bin/onie-nos-mode ]; then
    /bin/onie-nos-mode -s
fi

echo "Installation complete."
INSTALL_EOF
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
