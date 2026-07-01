#!/bin/sh

# NOS first-time setup script, invoked by cloud-init on first boot.

set -e

echo "nos-setup: running first-time initialization..."

# Allow raw-packet capable ping (kept from previous first-boot setup).
/usr/sbin/setcap cap_net_raw=ep /usr/bin/ping 2>/dev/null || true

# ---------------------------------------------------------------------------
# Parse /etc/machine.conf (key=value) to obtain ONIE platform information.
# ---------------------------------------------------------------------------
read_conf_file() {
    conf_file="$1"
    while IFS='=' read -r var value || [ -n "$var" ]; do
        var=$(echo "$var" | tr -d '\r\n')
        value=$(echo "$value" | tr -d '\r\n')
        # Strip inline comments.
        var=${var%#*}
        value=${value%#*}
        [ -z "$var" ] && continue
        # Trim surrounding quotes.
        tmp_val=${value#\"}
        value=${tmp_val%\"}
        eval "$var=\"$value\""
    done < "$conf_file"
}

ONIE_PLATFORM=""
if [ -r /etc/machine.conf ]; then
    read_conf_file "/etc/machine.conf"
elif [ -r /host/machine.conf ]; then
    read_conf_file "/host/machine.conf"
fi

ONIE_PLATFORM="${onie_platform:-}"
ONIE_SWITCH_ASIC="${onie_switch_asic:-}"
echo "nos-setup: onie_platform=${ONIE_PLATFORM:-unknown}"
echo "nos-setup: onie_switch_asic=${ONIE_SWITCH_ASIC:-unknown}"

# ---------------------------------------------------------------------------
# Install platform-specific packages from the local filesystem.
# The .debs are staged at build time under /usr/share/sonic/platform/<dir>/.
# ---------------------------------------------------------------------------
# Install opennsl only on Broadcom (bcm) switch ASICs.
if [ "$ONIE_SWITCH_ASIC" = "bcm" ]; then
    BCM_DIR="/usr/share/sonic/platform/bcm"
    echo "nos-setup: installing opennsl from $BCM_DIR..."
    if ls "$BCM_DIR"/opennsl-modules_*.deb >/dev/null 2>&1; then
        dpkg -i "$BCM_DIR"/opennsl-modules_*.deb
    else
        echo "nos-setup: WARNING, no opennsl .deb found in $BCM_DIR"
    fi
    echo "nos-setup: installing libsaibcm from $BCM_DIR..."
    if ls "$BCM_DIR"/libsaibcm_*.deb >/dev/null 2>&1; then
        dpkg -i "$BCM_DIR"/libsaibcm_*.deb
    else
        echo "nos-setup: WARNING, no libsaibcm .deb found in $BCM_DIR"
    fi
else
    echo "nos-setup: onie_switch_asic is '${ONIE_SWITCH_ASIC:-unknown}', skipping opennsl"
fi

# Install platform-modules for the detected platform.
PLATFORM_DIR="/usr/share/sonic/platform/$ONIE_PLATFORM"
case "$ONIE_PLATFORM" in
    x86_64-dellemc_s5232f_c3538-r0)
        echo "nos-setup: installing platform-modules-s5232f from $PLATFORM_DIR..."
        if ls "$PLATFORM_DIR"/platform-modules-s5232f_*.deb >/dev/null 2>&1; then
            dpkg -i "$PLATFORM_DIR"/platform-modules-s5232f_*.deb
        else
            echo "nos-setup: WARNING, no platform-modules .deb found in $PLATFORM_DIR"
        fi
        ;;
    *)
        echo "nos-setup: no platform-modules package mapped for '${ONIE_PLATFORM:-unknown}'"
        ;;
esac

# ---------------------------------------------------------------------------
# Symlink /usr/share/sonic/hwsku -> /usr/share/sonic/device/$onie_platform/$DEFAULT_SKU
# ---------------------------------------------------------------------------
if [ -n "$ONIE_PLATFORM" ]; then
    DEVICE_DIR="/usr/share/sonic/device/$ONIE_PLATFORM"
    HWSKU_DST="/usr/share/sonic/hwsku"
    DEFAULT_SKU_FILE="$DEVICE_DIR/default_sku"
    if [ -f "$DEFAULT_SKU_FILE" ]; then
        DEFAULT_SKU=$(awk '{print $1}' "$DEFAULT_SKU_FILE")
        HWSKU_SRC="$DEVICE_DIR/$DEFAULT_SKU"
        if [ -d "$HWSKU_SRC" ]; then
            mkdir -p "$(dirname "$HWSKU_DST")"
            rm -f "$HWSKU_DST"
            ln -s "$HWSKU_SRC" "$HWSKU_DST"
            echo "nos-setup: linked $HWSKU_DST -> $HWSKU_SRC"
        else
            echo "nos-setup: WARNING, $HWSKU_SRC not present, skipping hwsku symlink"
        fi
    else
        echo "nos-setup: WARNING, $DEFAULT_SKU_FILE not present, skipping hwsku symlink"
    fi
else
    echo "nos-setup: WARNING, onie_platform is empty, skipping hwsku symlink"
fi

# Clean up apt cache to save space on the image.
apt-get clean
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

echo "nos-setup: first-time initialization complete"

exit 0
