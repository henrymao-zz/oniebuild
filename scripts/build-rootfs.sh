#!/bin/bash
set -euo pipefail

ARCH=""
SUITE=""
MIRROR=""
COMPONENTS=""
ROOTFS=""
OVERLAY=""
NOS_NAME=""
NOS_VERSION=""
INCLUDE_DOCKER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        --components) COMPONENTS="$2"; shift 2 ;;
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --overlay) OVERLAY="$2"; shift 2 ;;
        --nos-name) NOS_NAME="$2"; shift 2 ;;
        --nos-version) NOS_VERSION="$2"; shift 2 ;;
        --include-docker) INCLUDE_DOCKER="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

: "${ARCH:=x86_64}"
: "${SUITE:=noble}"
: "${MIRROR:=http://archive.ubuntu.com/ubuntu}"
: "${COMPONENTS:=main,universe}"
: "${NOS_NAME:=ONIECraft}"
: "${NOS_VERSION:=1.0.0}"
: "${INCLUDE_DOCKER:=n}"

DEBARCH="$ARCH"
if [[ "$ARCH" == "x86_64" ]]; then
    DEBARCH="amd64"
elif [[ "$ARCH" == "arm64" ]]; then
    DEBARCH="arm64"
fi

if [[ -z "${ROOTFS:-}" ]]; then
    echo "ERROR: --rootfs is required"
    exit 1
fi

ROOTFS="$(readlink -f "$ROOTFS")"

command -v debootstrap >/dev/null 2>&1 || {
    echo "ERROR: debootstrap is not installed. Install it with: sudo apt install debootstrap"
    exit 1
}

echo "Building rootfs for $DEBARCH $SUITE..."

if [[ "$DEBARCH" != "$(dpkg --print-architecture)" ]]; then
    command -v qemu-${DEBARCH}-static >/dev/null 2>&1 || {
        echo "ERROR: qemu-user-static is required for cross-architecture builds"
        exit 1
    }
    DEBOOTSTRAP_OPTS="--no-check-gpg"
    if [[ -d "$ROOTFS" ]]; then
        sudo rm -rf "$ROOTFS"
    fi
    sudo debootstrap ${DEBOOTSTRAP_OPTS} --arch="$DEBARCH" --variant=minbase --components="$COMPONENTS" "$SUITE" "$ROOTFS" "$MIRROR"
    sudo cp /usr/bin/qemu-${DEBARCH}-static "$ROOTFS/usr/bin/"
else
    if [[ -d "$ROOTFS" ]]; then
        sudo rm -rf "$ROOTFS"
    fi
    sudo debootstrap --arch="$DEBARCH" --variant=minbase --components="$COMPONENTS" "$SUITE" "$ROOTFS" "$MIRROR"
fi

echo "Configuring rootfs..."

sudo tee "$ROOTFS/etc/hostname" >/dev/null <<< "$NOS_NAME"

sudo tee "$ROOTFS/etc/hosts" >/dev/null <<< "127.0.0.1 localhost $NOS_NAME"

sudo bash -c "cat > '$ROOTFS/etc/apt/sources.list'" <<EOF
deb $MIRROR $SUITE ${COMPONENTS//,/ }
deb $MIRROR $SUITE-updates ${COMPONENTS//,/ }
deb $MIRROR $SUITE-security ${COMPONENTS//,/ }
EOF

sudo mkdir -p "$ROOTFS/etc/apt/apt.conf.d"
sudo tee "$ROOTFS/etc/apt/apt.conf.d/81norecommends" >/dev/null <<'EOF'
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF

sudo tee "$ROOTFS/etc/apt/apt.conf.d/no-languages" >/dev/null <<'EOF'
Acquire::Languages "none";
EOF

sudo tee "$ROOTFS/etc/apt/apt.conf.d/gzip-indexes" >/dev/null <<'EOF'
Acquire::GzipIndexes "true";
EOF

sudo chroot "$ROOTFS" apt-get update

echo "Installing minimal system packages..."
sudo chroot "$ROOTFS" apt-get install -y --no-install-recommends \
    systemd \
    systemd-sysv \
    systemd-resolved \
    libpam-systemd \
    dbus \
    iproute2 \
    iputils-ping \
    isc-dhcp-client \
    openssh-server \
    sudo \
    less \
    kmod \
    initramfs-tools \
    ca-certificates \
    curl \
    gpg \
    locales \
    logrotate \
    zstd \
    net-tools \
    netplan.io \
    snapd \
    fancontrol \
    vim \
    bird3 \
    cloud-init

if [[ "$DEBARCH" == "arm64" ]]; then
    sudo chroot "$ROOTFS" apt-get install -y --no-install-recommends \
        u-boot-tools
fi

if [[ "$INCLUDE_DOCKER" == "y" ]]; then
    echo "Installing Docker..."
    sudo chroot "$ROOTFS" bash -c '
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu '$(lsb_release -cs)' stable" > /etc/apt/sources.list.d/docker.list
        apt-get update
        apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
        apt-get clean
        rm -rf /var/lib/apt/lists/*
    '
fi

echo "Cleaning up rootfs..."
sudo chroot "$ROOTFS" apt-get autoremove -y
sudo chroot "$ROOTFS" apt-get autoclean -y
sudo chroot "$ROOTFS" apt-get clean
sudo rm -rf "$ROOTFS/var/lib/apt/lists/"*
sudo rm -rf "$ROOTFS/var/cache/apt/archives/"*
sudo rm -rf "$ROOTFS/var/cache/apt/*.bin"

sudo chroot "$ROOTFS" bash -c "echo 'root:root' | chpasswd"
sudo chroot "$ROOTFS" passwd -l root

sudo chroot "$ROOTFS" useradd -m -s /bin/bash admin
sudo chroot "$ROOTFS" bash -c "echo 'admin:admin' | chpasswd"
sudo chroot "$ROOTFS" usermod -aG sudo admin

# Grant admin full sudo with no password
sudo tee "$ROOTFS/etc/sudoers.d/admin" >/dev/null <<'EOF'
admin ALL=(ALL) NOPASSWD:ALL
EOF
sudo chmod 0440 "$ROOTFS/etc/sudoers.d/admin"

# Disable root SSH login (and ensure it takes precedence)
if grep -q "^PermitRootLogin" "$ROOTFS/etc/ssh/sshd_config"; then
    sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$ROOTFS/etc/ssh/sshd_config"
else
    echo "PermitRootLogin no" | sudo tee -a "$ROOTFS/etc/ssh/sshd_config" >/dev/null
fi

sudo mkdir -p "$ROOTFS/lib/oniecraft"
sudo touch "$ROOTFS/lib/oniecraft/firsttime"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FILES_DIR="$PROJECT_DIR/files"

sudo cp "$FILES_DIR/rc.local" "$ROOTFS/etc/rc.local"
sudo chmod +x "$ROOTFS/etc/rc.local"

sudo chroot "$ROOTFS" systemctl enable ssh
sudo chroot "$ROOTFS" systemctl enable systemd-resolved
sudo chroot "$ROOTFS" systemctl enable systemd-networkd
sudo chroot "$ROOTFS" systemctl enable bird
sudo chroot "$ROOTFS" systemctl enable snapd.socket 2>/dev/null || true
sudo chroot "$ROOTFS" systemctl enable apparmor 2>/dev/null || true
sudo chroot "$ROOTFS" systemctl enable cloud-init-local.service 2>/dev/null || true
sudo chroot "$ROOTFS" systemctl enable cloud-init-init.service 2>/dev/null || true
sudo chroot "$ROOTFS" systemctl enable cloud-config.service 2>/dev/null || true
sudo chroot "$ROOTFS" systemctl enable cloud-final.service 2>/dev/null || true

sudo mkdir -p "$ROOTFS/etc/cloud/cloud.cfg.d"
sudo "$FILES_DIR/../scripts/gen-cloud-init.sh" \
    --files-dir "$FILES_DIR" \
    --output "$ROOTFS/etc/cloud/cloud.cfg.d/99-oniecraft-nocloud.cfg" \
    --nos-name "$NOS_NAME"

sudo mkdir -p "$ROOTFS/etc/systemd/system/docker.service.d"
sudo cp "$FILES_DIR/etc/systemd/system/docker.service.d/override.conf" \
    "$ROOTFS/etc/systemd/system/docker.service.d/override.conf"

if [[ "$INCLUDE_DOCKER" == "y" ]]; then
    sudo chroot "$ROOTFS" systemctl enable docker
fi

if [[ -d "${OVERLAY:-}" ]]; then
    OVERLAY="$(readlink -f "$OVERLAY")"
    echo "Applying overlay from $OVERLAY..."
    sudo rsync -a "$OVERLAY/" "$ROOTFS/"
fi

sudo mkdir -p "$ROOTFS/lib/$NOS_NAME"
sudo bash -c "cat > '$ROOTFS/lib/$NOS_NAME/machine.conf'" <<EOF
machine=$NOS_NAME
platform=$NOS_NAME-$ARCH
nos_name=$NOS_NAME
nos_version=$NOS_VERSION
nos_arch=$ARCH
EOF

sudo chroot "$ROOTFS" bash -c "cat > /etc/os-release" <<EOF
NAME="$NOS_NAME"
VERSION="$NOS_VERSION"
ID=$NOS_NAME
ID_LIKE=debian
VERSION_ID="$NOS_VERSION"
VERSION_CODENAME=$SUITE
PRETTY_NAME="$NOS_NAME $NOS_VERSION"
HOME_URL="https://github.com/example/oniecraft"
SUPPORT_URL="https://github.com/example/oniecraft"
BUG_REPORT_URL="https://github.com/example/oniecraft/issues"
EOF

echo "Rootfs build complete: $ROOTFS"
