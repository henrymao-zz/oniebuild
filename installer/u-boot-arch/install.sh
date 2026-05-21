#!/bin/sh

set -e

cd $(dirname $0)
. ./machine.conf

echo "Installer: platform=$platform"

install_uimage() {
    echo "Copying image to NOR flash:"
    itb_file="demo-${platform}.itb"
    if [ -f "$itb_file" ]; then
        flashcp -v "$itb_file" $mtd_dev
    else
        echo "ERROR: Image file not found: $itb_file"
        exit 1
    fi
}

hw_load() {
    echo "cp.b $img_start \$loadaddr $img_sz"
}

. ./platform.conf

install_uimage

hw_load_str="$(hw_load)"

echo "Updating U-Boot environment variables"
(cat <<EOF
hw_load $hw_load_str
copy_img echo "Loading Ubuntu $platform image..." && run hw_load
nos_bootcmd run copy_img && setenv bootargs quiet console=\$consoledev,\$baudrate && bootm \$loadaddr
EOF
) > /tmp/env.txt

fw_setenv -f -s /tmp/env.txt

cd /

if [ -x /bin/onie-nos-mode ] ; then
    /bin/onie-nos-mode -s
fi

echo "Installation complete."
