# ONIECraft

Generate ONIE-compatible self-extracting installer images for network switches. Builds a complete Network Operating System (NOS) root filesystem from Ubuntu, packages it with a custom kernel and bootloader, and produces a single `.bin` file installable via ONIE's `nos-install` mechanism.

## Overview

- **Base OS**: Ubuntu 26.04 (Resolute)
- **Kernel**: `linux-sonic 7.0.0-1002.2` from `ppa:canonical-kernel-team/bootstrap`
- **Bootloader**: GRUB (BIOS + UEFI for x86_64), U-Boot (ARM64)
- **Architectures**: x86_64 (amd64), arm64
- **Output**: Self-extracting shell archive (`.bin`) with SHA1 verification

### Build Pipeline

```
rootfs → kernel → packages → image
```

1. **rootfs** — Bootstrap minimal Ubuntu via `debootstrap`, install systemd/ssh/networking
2. **kernel** — Install `linux-sonic` from PPA (or build from source, or use default)
3. **packages** — Install additional `.deb` files and/or build source packages
4. **image** — Strip, optimize, compress rootfs; package with kernel + initrd + installer scripts

## Dependencies

### Host Build (native)

```bash
sudo apt install -y make debootstrap squashfs-tools zstd mtools \
  qemu-system-x86 qemu-utils expect sshpass
```

For ARM64 cross-builds:
```bash
sudo apt install -y qemu-user-static gcc-aarch64-linux-gnu
```

For VM testing:
```bash
sudo apt install -y qemu-system-x86 qemu-utils expect ovmf
```

### Workshop Build (containerized)

[Workshop](https://snapcraft.io/workshop) + LXD:

```bash
sudo snap install workshop --classic
sudo snap install lxd --channel=6/stable
sudo lxd init --auto   # or configure manually
```

Workshop SDK dependencies are handled automatically by the container.

## Quick Start

### Host Build

```bash
# Build the ONIE installer image
make image

# Full VM test (builds ONIE disk, installs NOS, verifies boot)
make vm-test

# Incremental: rebuild only what changed
make kernel    # rebuild kernel step
make image     # repackage image
```

### Host VM Testing

```bash
# Full pipeline (create ONIE VM → install NOS → verify boot)
make vm-test

# Reuse existing ONIE base disk for faster iteration
make vm-test-quick

# Step by step
make vm-create    # Create VM disk with ONIE installed
make vm-install   # Install ONIECraft image onto VM
make vm-run       # Boot installed NOS interactively
```

### Workshop Build & Test (containerized)

```bash
# Launch workshop container
workshop launch

# Build inside container
workshop run oniecraft build

# Verify build artifacts
workshop run oniecraft test

# Interactive shell in workspace
workshop shell oniecraft
```

## Configuration

Edit `config.mk` or create `oniecraft.conf` for overrides:

```makefile
# Architecture and OS identity
ARCH ?= x86_64
NOS_NAME ?= Ubuntu
NOS_VERSION ?= 1.0.0

# Ubuntu base suite (26.04 = resolute)
UBUNTU_SUITE ?= resolute

# Bootloader: grub (x86_64) or uboot (arm64)
BOOTLOADER ?= grub

# Kernel from PPA (default)
KERNEL_PKG ?= linux-sonic
KERNEL_PPA ?= ppa:canonical-kernel-team/bootstrap

# Or build custom kernel from source
# KERNEL_SRC = /path/to/linux-source
# KERNEL_CONFIG = /path/to/.config

# VM testing
VM_MEM ?= 2048
VM_DISK_SIZE ?= 40
VM_FIRMWARE ?= bios
```

## Directory Layout

```
oniecraft/
  Makefile                 # Top-level build orchestration
  config.mk                # Default configuration
  workshop.yaml            # Workshop container definition
  scripts/
    build-rootfs.sh        # Root filesystem bootstrap
    build-kernel.sh        # Kernel install (PPA/source/default)
    build-packages.sh      # Additional packages
    mk-installer.sh        # ONIE installer image packaging
    build-vm.sh            # KVM VM testing
    build-with-imagecraft.sh  # imagecraft-based pipeline
  installer/
    sharch_body.sh         # Self-extracting archive template
    grub-arch/             # GRUB installer (x86_64)
    u-boot-arch/           # U-Boot installer (ARM)
  build/                   # Output directory
    rootfs/                # Root filesystem
    kernel/                # Kernel artifacts
    Ubuntu-*-installer.bin # Final installer image
    vm/                    # VM disk images
```

## Image Optimization

The packaging step automatically strips unnecessary content:

- **Firmware pruning**: Removes Intel WiFi, AMD/NVIDIA GPU, Broadcom, Qualcomm, MediaTek, etc.
- **Kernel modules**: Removes sound, media, GPU, DRM, staging drivers
- **Binaries**: Strips debug symbols from executables and kernel modules
- **Docs/locales**: Removes manpages, docs, non-English locales

Image size: ~321MB (down from 489MB before optimization).

## Installer Runtime

The self-extracting `.bin` installer:

1. Verifies SHA1 checksum
2. Extracts embedded rootfs archive
3. Detects ONIE boot device via `ONIE-BOOT` label
4. Creates/overwrites NOS partition (ext4, label `ONIE-DEMO-OS`)
5. Copies kernel + initrd, extracts rootfs
6. Configures GRUB with `root=LABEL=ONIE-DEMO-OS`
7. Switches ONIE to NOS boot mode

Default credentials: `root:root` (SSH enabled on port 22).
