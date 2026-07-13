NOS_NAME ?= Ubuntu
NOS_VERSION ?= 1.0.0
ARCH ?= x86_64
ROOTFS_TARBALL_NAME ?= ubuntu-nos-rootfs.tar.gz

# Values not in image-definition.yaml — set in config.mk
BOOTLOADER ?= grub
PART_SIZE_MB ?= 4096

GIT_BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
GIT_REV ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

ONIE_ISO_URL ?= https://packages.trafficmanager.net/public/onie/onie-recovery-x86_64-kvm_x86_64-r0.iso
ONIE_ISO ?= $(BUILDDIR)/vm/onie-recovery-x86_64-kvm_x86_64-r0.iso
VM_MEM ?= 4096
VM_DISK_SIZE ?= 40
VM_FIRMWARE ?= bios
VM_KVM_PORT ?= 9000
VM_SSH_PORT ?= 3041

BUILDDIR ?= build

SERIES ?= resolute
PPA_NAME ?= henrymao/ubuntu-nos
PPA_URL ?= https://ppa.launchpadcontent.net/$(PPA_NAME)/ubuntu
LIBSAIBCM_URL ?= https://packages.trafficmanager.net/public/sai/sai-broadcom/SAI_11.2.0_GA-202405/11.2.30.5/xgs/libsaibcm_11.2.30.5_amd64.deb

IMAGE_NAME ?= $(NOS_NAME)-$(NOS_VERSION)-$(ARCH)-installer.bin

V ?= 0
ifeq ($(V),0)
Q := @
UI_DEBUG :=
else
Q :=
UI_DEBUG := --debug
endif
