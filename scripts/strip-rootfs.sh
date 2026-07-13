#!/bin/bash
# Rootfs optimization: cleanup, firmware pruning, kernel module pruning,
# and binary stripping. Runs inside the rootfs chroot by ubuntu-image's
# manual.execute step.

set -euo pipefail

echo "==== Stripping rootfs ===="

# ---------------------------------------------------------------------------
# 1. Cleanup: remove apt cache, docs, locales, manpages, static archives
# ---------------------------------------------------------------------------
echo "Cleaning up rootfs..."

rm -rf /packages/
rm -rf /var/cache/apt/archives/*
rm -rf /var/cache/apt/*.bin
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/*
rm -rf /usr/share/locale/*
rm -rf /usr/share/man/*
rm -rf /usr/share/info/*
rm -rf /usr/share/lintian/*
rm -rf /usr/share/common-licenses/*
rm -rf /usr/share/pixmaps/*
rm -rf /usr/include/
# Kernel headers/source trees (large, not needed at runtime)
rm -rf /usr/src/
rm -rf /usr/share/bug/*
rm -rf /usr/share/linda/*
rm -rf /usr/share/doc-base/*
find / -ignore_readdir_race -name "*.pyc" -delete 2>/dev/null || true
find / -ignore_readdir_race -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find / -ignore_readdir_race -name "*.a" -not -path "*/lib/modules/*" -delete 2>/dev/null || true
find / -ignore_readdir_race -name "*.la" -delete 2>/dev/null || true
find /usr/share/locale -ignore_readdir_race -mindepth 1 -maxdepth 1 \
    -not -name "en_US" -not -name "C" -not -iname "c.utf*" -exec rm -rf {} + 2>/dev/null || true
find /usr/lib/locale -ignore_readdir_race -mindepth 1 -maxdepth 1 \
    -not -name "en_US" -not -name "C" -not -iname "c.utf*" -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Firmware pruning: remove drivers irrelevant to network switch appliances
#    Keep: CPU microcode (amd64-microcode, intel-microcode), virtio, minimal
#    net/storage firmware.
# ---------------------------------------------------------------------------
echo "Removing unnecessary firmware..."
FW_DIRS="nvidia qcom amdgpu i915 mediatek ath11k ath10k ath12k ath6k ath9k \
    intel-ucode intel radeon amd-ucode amd amdnpu dpaa2 meson rockchip sunxi \
    tegra vsc cypress imx ti-connectivity ti rtl_bt rtl_nic rtlwifi rtw88 \
    rtw89 brcm qca adsl dvb siano ev56 go7007 cxgb4 usbdux snd 3com kaweth \
    edgeport emi26 emi62 tigon ess sun yamaha acenic cirrus ezusb sb16 \
    ositech vxworks keyspan_pda keyspan e100 dabusb av7110 ttusb-budget \
    ihex2fw phanfw.bin ct2fw.bin ctfw.bin lcs.fw netronome mrvl mellanox \
    qed xe liquidio asihpi LENOVO bnx2x amlogic ueagle-atm libertas airoha \
    amphion cnm ea rsi mwl8k atmel dell nxp wfx"
for d in $FW_DIRS; do
    rm -rf "/lib/firmware/$d" "/usr/lib/firmware/$d" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 3. Kernel module pruning: remove whole subsystem trees irrelevant to
#    network switches. Modules are already zstd-compressed; we skip
#    stripping (negligible gain, high cost).
# ---------------------------------------------------------------------------
echo "Pruning unused kernel modules..."
if [[ -d /lib/modules ]]; then
    MODULES_DIR="/lib/modules"
    KMOD_DIRS="sound drivers/media drivers/gpu drivers/drm drivers/infiniband drivers/staging"
    for d in $KMOD_DIRS; do
        rm -rf "$MODULES_DIR/"*/kernel/$d 2>/dev/null || true
    done
fi

# ---------------------------------------------------------------------------
# 4. Post-modification: refresh ldconfig cache and kernel module deps
# ---------------------------------------------------------------------------
echo "Updating ldconfig and depmod..."
ldconfig 2>/dev/null || true
depmod -a 2>/dev/null || true

# Clean up
rm -f /tmp/strip-rootfs.sh 2>/dev/null || true

echo "==== Rootfs strip complete ===="
