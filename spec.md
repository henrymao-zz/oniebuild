# ONIECraft Specification

## Purpose

ONIECraft generates ONIE-compatible self-extracting installer images for network switches. It builds a complete Network Operating System (NOS) root filesystem from Ubuntu, packages it with a kernel and bootloader configuration, and produces a single `.bin` file that can be installed via ONIE's `nos-install` mechanism.

## Build System

- **Makefile-driven**: GNU Make with stamp-file tracking for incremental builds
- **Shell scripts**: All build logic lives in `scripts/` as bash scripts with `set -euo pipefail`
- **Configuration**: Defaults in `config.mk`, overridden by `oniecraft.conf` or environment variables
- **Build targets**: `all` (default), `rootfs`, `kernel`, `packages`, `image`, `imagecraft`, `vm-create`, `vm-install`, `vm-run`, `vm-test`, `vm-test-quick`, `clean`, `distclean`

## Architecture Support

| Arch | Debian Arch | Bootloader | Cross-compile |
|------|------------|------------|---------------|
| x86_64 | amd64 | GRUB (UEFI/BIOS) | No |
| arm64 | arm64 | U-Boot | Yes (aarch64-linux-gnu-gcc) |

Cross-architecture rootfs builds require `qemu-user-static` and `debootstrap`.

## Build Pipeline

### 1. Root Filesystem (`scripts/build-rootfs.sh`)

- Bootstraps a minimal Ubuntu rootfs via `debootstrap` (--variant=minbase)
- Configures APT sources, apt.conf (no recommends, no languages, gzip indexes)
- Installs essential packages: systemd, iproute2, openssh-server, sudo, kmod, initramfs-tools, ca-certificates, curl, zstd
- Optionally installs Docker Engine (from docker.com apt repo)
- Sets up networking: systemd-networkd + netplan (DHCP on eth0)
- Enables services: ssh, systemd-resolved, systemd-networkd, docker (if included)
- Applies filesystem overlay from `overlay/` via rsync
- Writes `/etc/os-release` and `/lib/$NOS_NAME/machine.conf`
- Cleans APT caches and lists

### 2. Kernel (`scripts/build-kernel.sh`)

Three modes:
1. **Custom source build** (`KERNEL_SRC` set): Compiles kernel from source tree with optional `.config`, installs modules + headers + vmlinuz into rootfs, generates initramfs
2. **Pre-built package** (`KERNEL_VERSION` set without `KERNEL_SRC`): Installs `linux-image-$VERSION` via apt
3. **Default kernel** (neither set): Installs `linux-image-generic` (or `-arm64` variant) via apt

Cross-compilation for arm64 uses `CROSS_COMPILE=aarch64-linux-gnu-`.

### 3. Packages (`scripts/build-packages.sh`)

Installs additional packages from two sources:
- **.deb files**: Scanned from `packages/debs/*.deb` and `INCLUDE_DEBS` config; installed via `dpkg --root=$ROOTFS` with `apt-get install -f` for dependency resolution
- **Source packages**: Scanned from `packages/source/*/` and `INCLUDE_SOURCE_PKGS` config; auto-detects build system (Make, CMake, Python setuptools, or install.sh)

### 4. Image (`scripts/mk-installer.sh`)

- Strips rootfs: removes docs, locales, manpages, headers, debug firmware, `.pyc` files, `.a`/`.la` files
- Optimizes kernel modules: zstd recompression at level 19, strip debug symbols
- Strips user-space binaries
- Creates squashfs of rootfs (xz compression, excluding `/boot` and APT caches)
- Packages `demo.vmlinuz`, `demo.initrd`, `fs.squashfs`, `install.sh`, `machine.conf` into installer archive
- Wraps archive in self-extracting shell script (`installer/sharch_body.sh`) with SHA1 verification
- Output: `$NOS_NAME-$NOS_VERSION-$ARCH-installer.bin`

### 5. Imagecraft Build (`make imagecraft`)

Alternative build pipeline using [imagecraft](https://github.com/canonical/imagecraft) for rootfs creation instead of debootstrap:

- **imagecraft.yaml**: Manifest defining the image build:
  - `nil` plugin with `override-build` calling `mmdebstrap` directly (mmdebstrap plugin not registered in imagecraft 0.1.0)
  - `overlay-packages` installs `linux-image-generic`
  - `overlay-script` parts configure hostname, root password, services, apt, os-release, machine.conf, netplan
  - `build-base: ubuntu@22.04` required for destructive mode on 22.04 host
- **scripts/build-with-imagecraft.sh**: Post-processing script that:
  - Runs `imagecraft pack --destructive-mode`
  - Extracts rootfs from `pc.img` disk image via loop mount
  - Packages rootfs into ONIE installer `.bin` (same format as debootstrap pipeline)
- **Install**: `sudo snap install imagecraft --channel=beta --classic`
- Both pipelines produce identical ONIE installer format; `imagecraft` is an alternative to `make image`

## Installer Runtime

The self-extracting `.bin` installer:
1. Verifies its SHA1 checksum
2. Extracts to tmpfs (if root)
3. Runs `install.sh` which:
    - Detects ONIE boot device (`ONIE-BOOT` label)
    - Creates/overwrites NOS partition (GPT or MSDOS, configurable size)
    - Formats as ext4 with label `ONIE-DEMO-OS`
    - Copies kernel (`demo.vmlinuz`) + initrd (`demo.initrd`) to target with `root=LABEL=ONIE-DEMO-OS`
    - Installs squashfs rootfs via direct mount + `cp -a` (no overlayfs)
    - Configures bootloader (GRUB for x86_64 UEFI/BIOS, U-Boot env for ARM)
    - Switches ONIE to NOS mode

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `ARCH` | `x86_64` | Target architecture (x86_64, arm64) |
| `NOS_NAME` | `ONIECraft` | Network OS name |
| `NOS_VERSION` | `1.0.0` | Network OS version |
| `UBUNTU_SUITE` | `noble` | Ubuntu suite/codename |
| `UBUNTU_MIRROR` | `http://archive.ubuntu.com/ubuntu` | APT mirror URL |
| `UBUNTU_COMPONENTS` | `main,universe` | APT components |
| `BOOTLOADER` | `grub` | Bootloader type (grub, uboot) |
| `PART_SIZE_MB` | `4096` | Install partition size in MB |
| `INCLUDE_DOCKER` | `n` | Include Docker engine (y/n) |
| `KERNEL_SRC` | (empty) | Path to custom kernel source tree |
| `KERNEL_CONFIG` | (empty) | Path to kernel .config |
| `KERNEL_VERSION` | (empty) | Kernel version string / package name |
| `INCLUDE_DEBS` | (empty) | Space-separated .deb file paths |
| `INCLUDE_SOURCE_PKGS` | (empty) | Space-separated source pkg dirs |
| `V` | `0` | Verbose output (1=on) |
| `ONIE_ISO` | (empty) | Path to ONIE recovery ISO for KVM VM testing |
| `ONIE_ISO_URL` | `https://packages.trafficmanager.net/...` | URL to auto-download ONIE recovery ISO |
| `VM_MEM` | `2048` | VM memory in MB |
| `VM_DISK_SIZE` | `40` | VM disk size in GB |
| `VM_FIRMWARE` | `bios` | VM firmware: bios or uefi |
| `VM_KVM_PORT` | `9000` | KVM serial console telnet port |
| `VM_SSH_PORT` | `3041` | Host SSH port forwarded to VM |

## Directory Layout

```
oniecraft/
  Makefile              # Top-level build orchestration
  config.mk             # Default configuration values
  imagecraft.yaml       # imagecraft manifest (alternative build pipeline)
  oniecraft.conf.example # Example user config
  scripts/
    build-rootfs.sh     # Root filesystem bootstrap (debootstrap)
    build-kernel.sh     # Kernel build/install
    build-packages.sh   # Additional package installation
    mk-installer.sh     # ONIE installer image creation
    build-with-imagecraft.sh # imagecraft-based build pipeline
    build-vm.sh         # KVM VM creation and NOS installation
  installer/
    sharch_body.sh      # Self-extracting shell archive template
    grub-arch/          # GRUB bootloader installer (x86_64)
      install.sh
      grub.cfg
    u-boot-arch/        # U-Boot bootloader installer (ARM)
      install.sh
  overlay/              # Filesystem overlay (rsync'd into rootfs, debootstrap pipeline)
  packages/
    debs/               # Pre-built .deb packages
    source/             # Source packages to build
  kernel/               # Kernel build documentation
  build/                # Build output (rootfs, kernel, stamps, image)
    vm/                 # VM disk images and logs
```

## VM Testing (`scripts/build-vm.sh`)

Automated KVM-based testing pipeline inspired by [SONiC's build_kvm_image.sh](https://github.com/sonic-net/sonic-buildimage/blob/master/scripts/build_kvm_image.sh). Uses `qemu-system-x86_64` with `expect` to automate serial console interactions.

### Prerequisites

- `qemu-system-x86_64`, `qemu-img`, `expect`
- For UEFI: `ovmf` package
- ONIE recovery ISO for KVM x86_64 (build from [opencomputeproject/onie](https://github.com/opencomputeproject/onie) with `make MACHINE=kvm_x86_64 recovery-iso`)

### Commands

| Make Target | Script Command | Description |
|-------------|---------------|-------------|
| `vm-create` | `create` | Create qcow2 disk, boot ONIE ISO, select "embed" via expect to install ONIE |
| `vm-install` | `install` | Boot ONIE VM, mount installer disk, run `onie-installer.bin` via expect |
| `vm-run` | `run` | Boot installed NOS image interactively (SSH, VNC, serial) |
| `vm-test` | `test` | Full pipeline: create -> install ONIE -> install NOS -> verify boot (serial + SSH) |
| `vm-test-quick` | `test-quick` | Quick pipeline: install NOS -> verify boot (reuses existing ONIE disk) |

### VM Install Flow

1. **create**: `qemu-img create` -> boot from ONIE recovery ISO -> expect selects GRUB "ONIE: Embed ONIE" -> ONIE installed to disk
2. **install**: Boot from disk -> expect selects GRUB "ONIE: Install OS" -> kill ONIE discovery -> mount secondary virtio vfat disk containing installer -> execute `onie-installer.bin` -> NOS installed to ONIE partition
3. **test**: Runs all phases sequentially, then boots NOS and verifies via serial console (login prompt) + SSH (`sshpass` to check os-release, kernel, network, disk)
4. **test-quick**: Skips Phase 1 (ONIE embed), reuses existing ONIE disk, runs Phase 2 + Phase 3 only

### Key Implementation Details

- **Squashfs compression**: Must use `xz` (not zstd or lz4) — ONIE KVM recovery ISO kernel 5.4.86 only supports xz and gzip; xz chosen for better compression ratio
- **Installer disk format**: vfat (FAT32) partitioned — ONIE kernel cannot mount modern ext4 filesystems
- **Manual installer execution**: ONIE auto-discovery cannot mount secondary disk; instead, the expect script kills the discovery process, manually mounts `/dev/vdb1`, and runs the installer
- **Serial console mode**: QEMU uses `server` mode (not `nowait`) so expect connects before GRUB's 3-second timeout expires
- **ONIE updater completion**: Detected by monitoring `/var/log/onie.log` for `"ONIE: Success: Firmware update"`
- **GRUB linux command line**: Includes `root=LABEL=ONIE-DEMO-OS` so the kernel can find the root filesystem
- **SSH verification**: Reverted — serial console expect-based verification is sufficient and reliable

### Example

```bash
# Set ONIE ISO path
export ONIE_ISO=/path/to/onie-recovery-x86_64-kvm_x86_64-r0.iso

# Build + test in one command (debootstrap pipeline)
make image vm-test

# Or using imagecraft pipeline
make imagecraft vm-test

# Or step-by-step
make vm-create
make vm-install
make vm-run
```

## Requirements

- Host: Ubuntu/Debian with `debootstrap`, `squashfs-tools`, `mtools`
- Root/sudo access for chroot and mount operations
- For cross-arch builds: `qemu-user-static`, cross-compiler toolchain
- ONIE-compatible target switch for installation
- For VM testing: `qemu-system-x86_64`, `qemu-img`, `expect`, `sshpass`, ONIE KVM recovery ISO (auto-downloaded)
