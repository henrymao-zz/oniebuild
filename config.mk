ONIECRAFT_VERSION ?= 1.0.0
NOS_NAME ?= Ubuntu
NOS_VERSION ?= 1.0.0

ARCH ?= x86_64
UBUNTU_SUITE ?= noble
UBUNTU_MIRROR ?= http://archive.ubuntu.com/ubuntu
UBUNTU_COMPONENTS ?= main,universe

BOOTLOADER ?= grub
PART_SIZE_MB ?= 4096

INCLUDE_DOCKER ?= n

KERNEL_SRC ?=
KERNEL_CONFIG ?=
KERNEL_VERSION ?=

INCLUDE_DEBS ?=
INCLUDE_SOURCE_PKGS ?=

ONIE_ISO_URL ?= https://packages.trafficmanager.net/public/onie/onie-recovery-x86_64-kvm_x86_64-r0.iso
ONIE_ISO ?= $(BUILDDIR)/vm/onie-recovery-x86_64-kvm_x86_64-r0.iso
VM_MEM ?= 2048
VM_DISK_SIZE ?= 40
VM_FIRMWARE ?= bios
VM_KVM_PORT ?= 9000
VM_SSH_PORT ?= 3041

BUILDDIR ?= build
STAMPDIR ?= $(BUILDDIR)/stamps
ROOTFS_DIR ?= $(BUILDDIR)/rootfs
KERNEL_DIR ?= $(BUILDDIR)/kernel
OVERLAY_DIR ?= overlay
PACKAGES_DEB_DIR ?= packages/debs
PACKAGES_SRC_DIR ?= packages/source

IMAGE_NAME ?= $(NOS_NAME)-$(NOS_VERSION)-$(ARCH)-installer.bin

V ?= 0
ifeq ($(V),0)
Q := @
else
Q :=
endif
