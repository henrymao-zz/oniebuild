# ONIEBuild

Generate ONIE-compatible self-extracting installer images for network switches. Builds a complete Network Operating System (NOS) root filesystem from Ubuntu, packages it with a custom kernel and bootloader, and produces a single `.bin` file installable via ONIE's `nos-install` mechanism.

## Overview

- **Base OS**: Ubuntu 26.04 (Resolute)
- **Kernel**: `linux-sonic 7.0.0-1002.2` from `ppa:canonical-kernel-team/bootstrap`
- **Bootloader**: GRUB (BIOS; installer also supports UEFI on target hardware)
- **Architectures**: x86_64 (amd64)
- **Output**: Self-extracting shell archive (`.bin`) with SHA1 verification
- **Rootfs builder**: `ubuntu-image classic` (Canonical's official image builder)
- **Seed**: `server-minimal` from the official Ubuntu seeds repo

### Build Pipeline

```
ubuntu-image classic → build-onie
```

1. **ubuntu-image classic** — Bootstraps rootfs from `server-minimal` seed, installs packages from `image-definition.yaml` (kernel, extra-packages, cloud-init, platform debs, strip)
2. **build-onie** — Packages rootfs tarball into ONIE self-extracting `.bin`

Build is artifact-based and incremental: Make tracks real outputs (`build/debs/*.deb` → `build/ubuntu-nos-rootfs.tar.gz` → `build/$(IMAGE_NAME)`) and rebuilds only when prerequisites change.

## Dependencies

```bash
sudo apt install -y make mtools zstd squashfs-tools curl
sudo snap install ubuntu-image --classic
```

### VM Testing

```bash
sudo apt install -y qemu-system-x86 qemu-utils expect
```

## Quick Start

```bash
# Build the ONIE installer image
make image

# Full VM test (builds ONIE disk, installs NOS, verifies boot)
make vm-test

# Step by step VM testing
make vm-create    # Create VM disk with ONIE installed
make vm-install   # Install ONIE image onto VM
make vm-run       # Boot installed NOS interactively
```

## Directory Layout

```
oniebuild/
  Makefile                    # Top-level build orchestration
  image-definition.yaml       # ubuntu-image classic input (seed, packages, cloud-init)
  build-onie.sh               # ONIE installer image packaging
  test-vm.sh                  # KVM VM testing
  strip-rootfs.sh           # Chroot rootfs optimization (firmware/module/binary pruning)
  onie/
    sharch_body.sh            # Self-extracting archive template
    grub-arch/                # GRUB installer (x86_64)
      install.sh              # ONIE partition/fs/GRUB setup
      grub.cfg                # GRUB stage-1 config
  runtime/
    firstboot.sh              # First-boot setup (cloud-init runcmd)
  build/                      # Output directory (gitignored)
    debs/                      # Downloaded platform .deb packages
    ubuntu-nos-rootfs.tar.gz   # Rootfs tarball (from ubuntu-image)
    Ubuntu-*-installer.bin     # Final installer image
    vm/                        # VM disk images
```

## Image Optimization

The `strip-rootfs.sh` script runs inside the ubuntu-image chroot and automatically prunes:

- **Firmware**: Intel WiFi, AMD/NVIDIA GPU, Broadcom, Qualcomm, MediaTek, etc.
- **Kernel modules**: sound, media, GPU, DRM, staging, infiniband
- **Kernel headers**: `/usr/src/` (325M+ savings)
- **Binaries**: debug symbols stripped from executables
- **Docs/locales**: manpages, docs, non-English locales

## Cloud-Init Customization

The image uses cloud-init (NoCloud datasource) for first-boot configuration, defined declaratively in `image-definition.yaml`:

- **User**: `admin:admin` with sudo access
- **SSH**: Root login disabled via `sshd_config.d` drop-in
- **Root lock**: Password locked via `chpasswd`
- **Services**: `systemd-networkd` enabled via `runcmd`
- **Bird**: Service drop-in to start after cloud-init
- **First-boot**: Runs `/usr/sbin/firstboot.sh` for platform setup

## Installer Runtime

The self-extracting `.bin` installer:

1. Verifies SHA1 checksum
2. Extracts embedded rootfs archive
3. Detects ONIE boot device via `ONIE-BOOT` label
4. Creates/overwrites NOS partition (ext4, label `UBUNTU-NOS`)
5. Extracts rootfs (including `/boot/` with kernel and initrd)
6. Configures GRUB with `root=LABEL=UBUNTU-NOS` and `/boot/vmlinuz`, `/boot/initrd.img`
7. Switches ONIE to NOS boot mode

Default credentials: `admin:admin` (SSH enabled on port 22, root login disabled).

## First-Boot Setup

On first boot, cloud-init (NoCloud datasource) runs `firstboot.sh`, which:

1. Parses `/etc/machine.conf` for `onie_platform` and `onie_switch_asic`
2. Installs Broadcom packages (opennsl, libsaibcm) if ASIC is `bcm`
3. Installs platform-modules `.deb` for the detected platform
4. Sets up `/usr/share/sonic/hwsku` symlink from `default_sku`
