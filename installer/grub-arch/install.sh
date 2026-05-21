#!/bin/sh

set -e

cd $(dirname $0)
. ./machine.conf

echo "Installer: platform=$platform"

blk_dev=$(blkid | grep ONIE-BOOT | awk '{print $1}' | sed -e 's/[1-9][0-9]*:.*$//' | sed -e 's/\([0-9]\)\(p\)/\1/' | head -n 1)
[ -b "$blk_dev" ] || { echo "Error: Unable to find ONIE block device"; exit 1; }

demo_type="%%DEMO_TYPE%%"
demo_volume_label="ONIE-DEMO-${demo_type}"

if [ -d "/sys/firmware/efi/efivars" ] ; then
    firmware="uefi"
else
    firmware="bios"
fi

onie_partition_type=$(onie-sysinfo -t)
demo_part_size=${part_size:-4096}

if [ "$firmware" = "uefi" ] ; then
    create_demo_partition="create_demo_uefi_partition"
elif [ "$onie_partition_type" = "gpt" ] ; then
    create_demo_partition="create_demo_gpt_partition"
elif [ "$onie_partition_type" = "msdos" ] ; then
    create_demo_partition="create_demo_msdos_partition"
else
    echo "ERROR: Unsupported partition type: $onie_partition_type"
    exit 1
fi

demo_part=
create_demo_gpt_partition()
{
    blk_dev="$1"
    demo_part=$(sgdisk -p $blk_dev | grep "$demo_volume_label" | awk '{print $1}')
    if [ -n "$demo_part" ] ; then
        sgdisk -d $demo_part $blk_dev || { echo "Error: Unable to delete partition"; exit 1; }
        partprobe
    fi
    last_part=$(sgdisk -p $blk_dev | tail -n 1 | awk '{print $1}')
    demo_part=$((last_part + 1))
    blk_suffix=
    echo ${blk_dev} | grep -q mmcblk && blk_suffix="p"
    echo ${blk_dev} | grep -q nvme && blk_suffix="p"
    sgdisk --new=${demo_part}::+${demo_part_size}MB \
        --change-name=${demo_part}:$demo_volume_label $blk_dev || { echo "Error: Unable to create partition"; exit 1; }
    partprobe
}

create_demo_msdos_partition()
{
    blk_dev="$1"
    part_info="$(blkid | grep $demo_volume_label | awk -F: '{print $1}')"
    if [ -n "$part_info" ] ; then
        demo_part="$(echo -n $part_info | sed -e s#${blk_dev}##)"
        parted -s $blk_dev rm $demo_part || { echo "Error: Unable to delete partition"; exit 1; }
        partprobe
    fi
    last_part_info="$(parted -s -m $blk_dev unit s print | tail -n 1)"
    last_part_num="$(echo -n $last_part_info | awk -F: '{print $1}')"
    last_part_end="$(echo -n $last_part_info | awk -F: '{print $3}')"
    last_part_end=${last_part_end%s}
    demo_part=$((last_part_num + 1))
    demo_part_start=$((last_part_end + 1))
    sectors_per_mb=2048
    demo_part_end=$((demo_part_start + (demo_part_size * sectors_per_mb) - 1))
    parted -s --align optimal $blk_dev unit s \
        mkpart primary $demo_part_start $demo_part_end set $demo_part boot on || { echo "Error: Unable to create partition"; exit 1; }
    partprobe
}

create_demo_uefi_partition()
{
    create_demo_gpt_partition "$1"
    for b in $(efibootmgr | grep "$demo_volume_label" | awk '{ print $1 }') ; do
        local num=${b#Boot}
        num=${num%\*}
        efibootmgr -b $num -B > /dev/null 2>&1
    done
}

eval $create_demo_partition $blk_dev
demo_dev=$(echo $blk_dev | sed -e 's/\(mmcblk[0-9]\)/\1p/')$demo_part
echo $blk_dev | grep -q nvme && {
    demo_dev=$(echo $blk_dev | sed -e 's/\(nvme[0-9]n[0-9]\)/\1p/')$demo_part
}
partprobe 2>/dev/null || blockdev --rereadpt $blk_dev 2>/dev/null || true
sleep 2
partprobe 2>/dev/null || true

mkfs.ext4 -F -L $demo_volume_label $demo_dev || { echo "Error: Unable to create filesystem"; exit 1; }

demo_mnt=$(mktemp -d) || { echo "Error: Unable to create mount point"; exit 1; }
mount -t ext4 -o defaults,rw $demo_dev $demo_mnt || { echo "Error: Unable to mount partition"; exit 1; }

cp demo.vmlinuz demo.initrd $demo_mnt/

if [ -f fs.squashfs ]; then
    echo "Mounting squashfs rootfs..."
    mkdir -p /tmp/rootfs_squash
    mount -t squashfs -o ro fs.squashfs /tmp/rootfs_squash || { echo "Error: Unable to mount squashfs"; exit 1; }

    echo "Copying rootfs to target..."
    cp -a /tmp/rootfs_squash/. "$demo_mnt/"

    umount /tmp/rootfs_squash
    rm -rf /tmp/rootfs_squash
    rm -f fs.squashfs
fi

[ -r ./platform.conf ] && . ./platform.conf

if [ -r $onie_root_dir/grub/grub-variables ] ; then
    . $onie_root_dir/grub/grub-variables 2>/dev/null || true
fi

GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:-console=tty0 console=ttyS0,115200n8}"

grub_cfg=$(mktemp)

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

menuentry 'Ubuntu $demo_type' --unrestricted {
        search --no-floppy --label --set=root $demo_volume_label
        echo    'Loading Ubuntu $demo_type kernel ...'
        linux   /demo.vmlinuz root=LABEL=$demo_volume_label $GRUB_CMDLINE_LINUX \$ONIE_EXTRA_CMDLINE_LINUX DEMO_TYPE=$demo_type
        echo    'Loading Ubuntu $demo_type initial ramdisk ...'
        initrd  /demo.initrd
}
EOF

if [ -x $onie_root_dir/grub.d/50_onie_grub ]; then
    $onie_root_dir/grub.d/50_onie_grub >> $grub_cfg 2>/dev/null || true
fi

if [ "$firmware" = "uefi" ] ; then
    echo "Configuring UEFI boot..."
    grub-install --no-nvram \
        --bootloader-id="$demo_volume_label" \
        --efi-directory="/boot/efi" \
        --boot-directory="$demo_mnt" \
        --recheck "$blk_dev" 2>/dev/null || true

    uefi_part=0
    for p in $(seq 8) ; do
        if sgdisk -i $p $blk_dev | grep -q C12A7328-F81F-11D2-BA4B-00A0C93EC93B ; then
            uefi_part=$p
            break
        fi
    done

    [ $uefi_part -ne 0 ] && {
        efibootmgr --quiet --create \
            --label "$demo_volume_label" \
            --disk $blk_dev --part $uefi_part \
            --loader "/EFI/$demo_volume_label/grubx64.efi" 2>/dev/null || true
    }
else
    echo "Configuring BIOS boot..."
    grub-install --target=i386-pc \
        --boot-directory="$demo_mnt" \
        --recheck "$blk_dev" 2>/dev/null || true
fi

mkdir -p $demo_mnt/grub
cp $grub_cfg $demo_mnt/grub/grub.cfg
rm -f $grub_cfg

onie-support $demo_mnt 2>/dev/null || true

umount $demo_mnt || true

if [ "$demo_type" = "OS" ] ; then
    if [ -x /bin/onie-nos-mode ] ; then
        /bin/onie-nos-mode -s
    fi
fi

echo "Installation complete."
