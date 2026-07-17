#!/bin/bash
set -euo pipefail

ARCH=""
ROOTFS_TARBALL=""
NOS_NAME=""
NOS_VERSION=""
GIT_BRANCH=""
GIT_REV=""
PART_SIZE=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --rootfs-tarball) ROOTFS_TARBALL="$2"; shift 2 ;;
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
: "${NOS_NAME:=Ubuntu-NOS}"
: "${NOS_VERSION:=1.0.0}"
: "${GIT_BRANCH:=unknown}"
: "${GIT_REV:=unknown}"
: "${PART_SIZE:=4096}"
: "${ROOTFS_TARBALL:=build/ubuntu-nos-rootfs.tar.gz}"

if [[ -z "${OUTPUT:-}" ]]; then
    OUTPUT="build/${NOS_NAME}-${NOS_VERSION}-${ARCH}-installer.bin"
fi

ROOTFS_TARBALL="$(readlink -f "$ROOTFS_TARBALL")"

if [[ ! -f "$ROOTFS_TARBALL" ]]; then
    echo "ERROR: Rootfs tarball not found: $ROOTFS_TARBALL"
    exit 1
fi

# Determine kernel version from the tarball contents
KVER=$(tar -tf "$ROOTFS_TARBALL" | grep -oP 'boot/vmlinuz-\K.*' | head -1)

if [[ -z "$KVER" ]]; then
    echo "ERROR: Could not determine kernel version from tarball"
    exit 1
fi

echo "Packaging ONIE installer image..."
echo "  Kernel version: $KVER"
echo "  Architecture:   $ARCH"

TMP_DIR=$(mktemp -d)
trap 'rm -rf $TMP_DIR' EXIT

INSTALLER_TMP="$TMP_DIR/installer"
mkdir -p "$INSTALLER_TMP"

echo "Using rootfs tarball directly as fs.tar.gz..."
cp "$ROOTFS_TARBALL" "$INSTALLER_TMP/fs.tar.gz"

cp -r onie/grub-arch/* "$INSTALLER_TMP/"

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

chmod +x "$INSTALLER_TMP/install.sh"

SHARCH="$TMP_DIR/sharch.tar"
tar -C "$TMP_DIR" -cf "$SHARCH" installer || {
    echo "ERROR: Failed to create installer archive"
    exit 1
}

SHA1=$(sha1sum "$SHARCH" | awk '{print $1}')

SHARCH_BODY="onie/sharch_body.sh"
if [[ ! -f "$SHARCH_BODY" ]]; then
    echo "ERROR: sharch_body.sh template not found: $SHARCH_BODY"
    exit 1
fi

cp "$SHARCH_BODY" "$OUTPUT"
sed -i -e "s/%%IMAGE_SHA1%%/$SHA1/" "$OUTPUT"
cat "$SHARCH" >> "$OUTPUT"
chmod +x "$OUTPUT"

echo ""
echo "Success: ONIE installer image created:"
ls -lh "$OUTPUT"
