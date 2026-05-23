include config.mk

-include oniecraft.conf

.PHONY: all rootfs kernel packages image imagecraft vm-create vm-install vm-run vm-test vm-test-quick clean distclean help

all: image

help:
	@echo "ONIECraft - Build ONIE-compatible installer images"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Build the complete ONIE installer image (default)"
	@echo "  rootfs    - Build the root filesystem"
	@echo "  kernel    - Build or prepare the kernel"
	@echo "  packages  - Install additional packages"
	@echo "  image     - Package into ONIE installer image"
	@echo "  imagecraft - Build ONIE installer image using imagecraft"
	@echo "  clean     - Remove build artifacts (keep downloads)"
	@echo "  distclean - Remove everything including downloads"
	@echo ""
	@echo "Configuration (set in oniecraft.conf or environment):"
	@echo "  ARCH              - Target architecture (x86_64, arm64) [$(ARCH)]"
	@echo "  NOS_NAME          - Network OS name [$(NOS_NAME)]"
	@echo "  NOS_VERSION       - Network OS version [$(NOS_VERSION)]"
	@echo "  UBUNTU_SUITE      - Ubuntu suite/codename [$(UBUNTU_SUITE)]"
	@echo "  BOOTLOADER        - Bootloader type: grub or uboot [$(BOOTLOADER)]"
	@echo "  PART_SIZE_MB      - Install partition size in MB [$(PART_SIZE_MB)]"
	@echo "  INCLUDE_DOCKER    - Include Docker engine (y/n) [$(INCLUDE_DOCKER)]"
	@echo "  KERNEL_SRC        - Path to custom kernel source tree [$(KERNEL_SRC)]"
	@echo "  KERNEL_CONFIG     - Path to kernel .config file [$(KERNEL_CONFIG)]"
	@echo "  KERNEL_VERSION    - Kernel version string [$(KERNEL_VERSION)]"
	@echo "  KERNEL_PKG        - Kernel package name (e.g. linux-sonic) [$(KERNEL_PKG)]"
	@echo "  KERNEL_PPA        - PPA for custom kernel (e.g. ppa:canonical-kernel-team/bootstrap) [$(KERNEL_PPA)]"
	@echo "  INCLUDE_DEBS      - Space-separated list of .deb files to install [$(INCLUDE_DEBS)]"
	@echo "  INCLUDE_SOURCE_PKGS - Space-separated source pkg dirs to build and install [$(INCLUDE_SOURCE_PKGS)]"
	@echo "  V                 - Verbose output (1=on, 0=off) [$(V)]"
	@echo ""
	@echo "VM Testing Targets (require ONIE recovery ISO):"
	@echo "  vm-create   - Create KVM VM with ONIE installed from recovery ISO"
	@echo "  vm-install  - Install ONIECraft image onto existing ONIE VM"
	@echo "  vm-run      - Boot the installed NOS image in the VM"
	@echo "  vm-test     - Full pipeline: create -> install NOS -> verify boot"
	@echo "  vm-test-quick - Quick pipeline: install NOS -> verify boot (reuses ONIE disk)"
	@echo ""
	@echo "VM Configuration:"
	@echo "  ONIE_ISO    - Path to ONIE recovery ISO (KVM x86_64) [$(ONIE_ISO)]"
	@echo "  VM_MEM      - VM memory in MB [$(VM_MEM)]"
	@echo "  VM_DISK_SIZE - VM disk size in GB [$(VM_DISK_SIZE)]"
	@echo "  VM_FIRMWARE - Boot firmware: bios or uefi [$(VM_FIRMWARE)]"
	@echo "  VM_KVM_PORT - KVM serial console telnet port [$(VM_KVM_PORT)]"
	@echo "  VM_SSH_PORT - Host SSH forwarding port [$(VM_SSH_PORT)]"

rootfs: $(STAMPDIR)/rootfs

kernel: $(STAMPDIR)/kernel

packages: $(STAMPDIR)/packages

image: $(STAMPDIR)/image

$(STAMPDIR)/rootfs: | $(STAMPDIR) $(BUILDDIR)
	$(Q)echo "==== Building root filesystem ===="
	$(Q)sudo scripts/build-rootfs.sh \
		--arch "$(ARCH)" \
		--suite "$(UBUNTU_SUITE)" \
		--mirror "$(UBUNTU_MIRROR)" \
		--components "$(UBUNTU_COMPONENTS)" \
		--rootfs "$(ROOTFS_DIR)" \
		--overlay "$(OVERLAY_DIR)" \
		--nos-name "$(NOS_NAME)" \
		--nos-version "$(NOS_VERSION)" \
		--include-docker "$(INCLUDE_DOCKER)"
	$(Q)touch $@

$(STAMPDIR)/kernel: | $(STAMPDIR) $(BUILDDIR)
	$(Q)echo "==== Building kernel ===="
	$(Q)sudo scripts/build-kernel.sh \
		--arch "$(ARCH)" \
		--kernel-src "$(KERNEL_SRC)" \
		--kernel-config "$(KERNEL_CONFIG)" \
		--kernel-version "$(KERNEL_VERSION)" \
		--kernel-pkg "$(KERNEL_PKG)" \
		--kernel-ppa "$(KERNEL_PPA)" \
		--builddir "$(KERNEL_DIR)" \
		--rootfs "$(ROOTFS_DIR)"
	$(Q)touch $@

$(STAMPDIR)/packages: $(STAMPDIR)/rootfs | $(STAMPDIR) $(BUILDDIR)
	$(Q)echo "==== Installing packages ===="
	$(Q)sudo scripts/build-packages.sh \
		--rootfs "$(ROOTFS_DIR)" \
		--debs-dir "$(PACKAGES_DEB_DIR)" \
		--source-dir "$(PACKAGES_SRC_DIR)" \
		--include-debs "$(INCLUDE_DEBS)" \
		--include-source "$(INCLUDE_SOURCE_PKGS)"
	$(Q)touch $@

$(STAMPDIR)/image: $(STAMPDIR)/rootfs $(STAMPDIR)/kernel $(STAMPDIR)/packages | $(STAMPDIR) $(BUILDDIR)
	$(Q)echo "==== Creating ONIE installer image ===="
	$(Q)sudo scripts/mk-installer.sh \
		--arch "$(ARCH)" \
		--bootloader "$(BOOTLOADER)" \
		--rootfs "$(ROOTFS_DIR)" \
		--kernel-dir "$(KERNEL_DIR)" \
		--nos-name "$(NOS_NAME)" \
		--nos-version "$(NOS_VERSION)" \
		--part-size "$(PART_SIZE_MB)" \
		--output "$(BUILDDIR)/$(IMAGE_NAME)"
	$(Q)touch $@

$(STAMPDIR):
	$(Q)mkdir -p $@

$(BUILDDIR):
	$(Q)mkdir -p $@

clean:
	$(Q)echo "==== Cleaning build artifacts ===="
	$(Q)sudo rm -rf $(ROOTFS_DIR) $(KERNEL_DIR) $(STAMPDIR)
	$(Q)sudo rm -f $(BUILDDIR)/$(IMAGE_NAME) $(BUILDDIR)/*.squashfs $(BUILDDIR)/*.zip

distclean: clean
	$(Q)echo "==== Removing all build data ===="
	$(Q)sudo rm -rf $(BUILDDIR)

vm-create:
	$(Q)scripts/build-vm.sh create \
		--onie-iso "$(ONIE_ISO)" \
		--onie-iso-url "$(ONIE_ISO_URL)" \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--mem "$(VM_MEM)" \
		--disk-size "$(VM_DISK_SIZE)" \
		--firmware "$(VM_FIRMWARE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-install:
	$(Q)scripts/build-vm.sh install \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--installer "$(BUILDDIR)/$(IMAGE_NAME)" \
		--firmware "$(VM_FIRMWARE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-run:
	$(Q)scripts/build-vm.sh run \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--firmware "$(VM_FIRMWARE)" \
		--mem "$(VM_MEM)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-test:
	$(Q)scripts/build-vm.sh test \
		--onie-iso "$(ONIE_ISO)" \
		--onie-iso-url "$(ONIE_ISO_URL)" \
		--installer "$(BUILDDIR)/$(IMAGE_NAME)" \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--mem "$(VM_MEM)" \
		--disk-size "$(VM_DISK_SIZE)" \
		--firmware "$(VM_FIRMWARE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-test-quick:
	$(Q)scripts/build-vm.sh test-quick \
		--installer "$(BUILDDIR)/$(IMAGE_NAME)" \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--mem "$(VM_MEM)" \
		--firmware "$(VM_FIRMWARE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

imagecraft:
	$(Q)echo "==== Building ONIE installer image with imagecraft ===="
	$(Q)scripts/build-with-imagecraft.sh \
		--arch "$(ARCH)" \
		--bootloader "$(BOOTLOADER)" \
		--nos-name "$(NOS_NAME)" \
		--nos-version "$(NOS_VERSION)" \
		--part-size "$(PART_SIZE_MB)" \
		--kernel-dir "$(KERNEL_DIR)" \
		--output "$(BUILDDIR)/$(IMAGE_NAME)"
