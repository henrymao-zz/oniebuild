#!/bin/bash
set -euo pipefail

ARCH=""
KERNEL_SRC=""
KERNEL_CONFIG=""
KERNEL_VERSION=""
BUILDDIR=""
ROOTFS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --kernel-src) KERNEL_SRC="$2"; shift 2 ;;
        --kernel-config) KERNEL_CONFIG="$2"; shift 2 ;;
        --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
        --builddir) BUILDDIR="$2"; shift 2 ;;
        --rootfs) ROOTFS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

: "${ARCH:=x86_64}"
: "${BUILDDIR:=build/kernel}"

BUILDDIR="$(readlink -f "$BUILDDIR")"
mkdir -p "$BUILDDIR"

KARCH="$ARCH"
if [[ "$ARCH" == "x86_64" ]]; then
    KARCH="x86_64"
elif [[ "$ARCH" == "arm64" ]]; then
    KARCH="arm64"
fi

CROSS_COMPILE=""
DEBARCH="$ARCH"
if [[ "$ARCH" == "x86_64" ]]; then
    DEBARCH="amd64"
elif [[ "$ARCH" == "arm64" ]]; then
    DEBARCH="arm64"
    if [[ "$(dpkg --print-architecture)" != "arm64" ]]; then
        CROSS_COMPILE="aarch64-linux-gnu-"
        command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || {
            echo "ERROR: aarch64-linux-gnu-gcc not found. Install: sudo apt install gcc-aarch64-linux-gnu"
            exit 1
        }
    fi
fi

if [[ -n "$KERNEL_SRC" ]]; then
    echo "Building kernel from source: $KERNEL_SRC"
    KERNEL_SRC="$(readlink -f "$KERNEL_SRC")"

    if [[ ! -d "$KERNEL_SRC" ]]; then
        echo "ERROR: Kernel source directory not found: $KERNEL_SRC"
        exit 1
    fi

    MAKE_ARGS=(-C "$KERNEL_SRC" O="$BUILDDIR" ARCH="$KARCH")
    if [[ -n "$CROSS_COMPILE" ]]; then
        MAKE_ARGS+=(CROSS_COMPILE="$CROSS_COMPILE")
    fi

    if [[ -n "$KERNEL_CONFIG" ]]; then
        KERNEL_CONFIG="$(readlink -f "$KERNEL_CONFIG")"
        if [[ ! -f "$KERNEL_CONFIG" ]]; then
            echo "ERROR: Kernel config not found: $KERNEL_CONFIG"
            exit 1
        fi
        cp "$KERNEL_CONFIG" "$BUILDDIR/.config"
        make "${MAKE_ARGS[@]}" olddefconfig
    else
        make "${MAKE_ARGS[@]}" defconfig
    fi

    echo "Compiling kernel..."
    make "${MAKE_ARGS[@]}" -j"$(nproc)"

    if [[ -n "$KERNEL_VERSION" ]]; then
        KVER="$KERNEL_VERSION"
    else
        KVER=$(make "${MAKE_ARGS[@]}" kernelrelease 2>/dev/null | tail -1)
    fi

    echo "Kernel version: $KVER"

    make "${MAKE_ARGS[@]}" modules_install INSTALL_MOD_PATH="$BUILDDIR/mod_install"
    make "${MAKE_ARGS[@]}" headers_install INSTALL_HDR_PATH="$BUILDDIR/hdr_install"

    cp "$BUILDDIR/arch/$KARCH/boot/bzImage" "$BUILDDIR/vmlinuz" 2>/dev/null || \
    cp "$BUILDDIR/arch/$KARCH/boot/Image" "$BUILDDIR/vmlinuz" 2>/dev/null || {
        echo "ERROR: Could not find compiled kernel image"
        exit 1
    }

    if [[ -n "${ROOTFS:-}" && -d "$ROOTFS" ]]; then
        ROOTFS="$(readlink -f "$ROOTFS")"
        echo "Installing kernel into rootfs..."

        sudo mkdir -p "$ROOTFS/boot"
        sudo cp "$BUILDDIR/vmlinuz" "$ROOTFS/boot/vmlinuz-$KVER"

        sudo mkdir -p "$ROOTFS/lib/modules/$KVER"
        sudo cp -a "$BUILDDIR/mod_install/lib/modules/$KVER/"* "$ROOTFS/lib/modules/$KVER/" 2>/dev/null || true

        echo "Generating initramfs..."
        sudo chroot "$ROOTFS" update-initramfs -c -k "$KVER" 2>/dev/null || \
        sudo chroot "$ROOTFS" mkinitramfs -o /boot/initrd.img-"$KVER" "$KVER" 2>/dev/null || {
            echo "WARNING: Could not generate initramfs automatically"
            echo "You may need to generate it manually or install linux-image package"
        }

        sudo ln -sf "vmlinuz-$KVER" "$ROOTFS/boot/vmlinuz" 2>/dev/null || true
        sudo ln -sf "initrd.img-$KVER" "$ROOTFS/boot/initrd.img" 2>/dev/null || true
    fi

elif [[ -n "$KERNEL_VERSION" ]]; then
    echo "Installing pre-built kernel package: linux-image-$KERNEL_VERSION"

    if [[ -n "${ROOTFS:-}" && -d "$ROOTFS" ]]; then
        ROOTFS="$(readlink -f "$ROOTFS")"
        sudo chroot "$ROOTFS" apt-get install -y --no-install-recommends "linux-image-${KERNEL_VERSION}" || {
            echo "ERROR: Failed to install kernel package"
            exit 1
        }

        sudo chroot "$ROOTFS" apt-get clean
        sudo rm -rf "$ROOTFS/var/cache/apt/archives/"*
        sudo rm -rf "$ROOTFS/var/lib/apt/lists/"*

        KVER="$KERNEL_VERSION"
    else
        echo "ERROR: --rootfs is required when using pre-built kernel packages"
        exit 1
    fi
else
echo "Installing default kernel for architecture $DEBARCH..."

if [[ -n "${ROOTFS:-}" && -d "$ROOTFS" ]]; then
    ROOTFS="$(readlink -f "$ROOTFS")"
    sudo chroot "$ROOTFS" apt-get update

    if [[ "$DEBARCH" == "amd64" ]]; then
            KERNEL_PKG="linux-image-generic"
        elif [[ "$DEBARCH" == "arm64" ]]; then
            KERNEL_PKG="linux-image-generic-arm64"
        else
            KERNEL_PKG="linux-image-generic"
        fi

        sudo chroot "$ROOTFS" apt-get install -y --no-install-recommends "$KERNEL_PKG" || {
            echo "ERROR: Failed to install default kernel package"
            exit 1
        }

        sudo chroot "$ROOTFS" apt-get clean
        sudo rm -rf "$ROOTFS/var/cache/apt/archives/"*
        sudo rm -rf "$ROOTFS/var/lib/apt/lists/"*

        KVER=$(ls "$ROOTFS/boot/vmlinuz-"* 2>/dev/null | head -1 | sed "s|.*vmlinuz-||")
        if [[ -z "$KVER" ]]; then
            echo "ERROR: Could not determine installed kernel version"
            exit 1
        fi
    else
        echo "ERROR: --rootfs is required when installing kernel packages"
        exit 1
    fi
fi

echo "$KVER" > "$BUILDDIR/.kernel_version"
echo "Kernel build complete. Version: $KVER"
