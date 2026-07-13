include config.mk

STAMPDIR ?= $(BUILDDIR)/stamps
UI_WORKDIR ?= $(BUILDDIR)/ui-workdir
FILES_DIR ?= $(BUILDDIR)/debs

.PHONY: all rootfs image vm-create vm-install vm-run vm-test clean distclean help

all: image

help:
	@echo "ONIEBuild - Build ONIE-compatible installer images"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Build the complete ONIE installer image (default)"
	@echo "  image     - Package into ONIE installer image"
	@echo "  clean     - Remove build artifacts (keep downloads)"
	@echo "  distclean - Remove everything including downloads"
	@echo ""
	@echo " — override via environment variables):"
	@echo "  NOS_NAME          - Network OS name [$(NOS_NAME)]"
	@echo "  NOS_VERSION       - Network OS version [$(NOS_VERSION)]"
	@echo "  BOOTLOADER        - Bootloader type: grub or uboot [$(BOOTLOADER)]"
	@echo "  PART_SIZE_MB      - Install partition size in MB [$(PART_SIZE_MB)]"
	@echo "  V                 - Verbose output (1=on, 0=off) [$(V)]"
	@echo ""
	@echo "VM Testing Targets (require ONIE recovery ISO):"
	@echo "  vm-create   - Create KVM VM with ONIE installed from recovery ISO"
	@echo "  vm-install  - Install ONIEBuild image onto existing ONIE VM"
	@echo "  vm-run      - Boot the installed NOS image in the VM"
	@echo "  vm-test     - Full pipeline: create -> install NOS -> verify boot"
	@echo ""
	@echo "VM Configuration:"
	@echo "  ONIE_ISO    - Path to ONIE recovery ISO (KVM x86_64) [$(ONIE_ISO)]"
	@echo "  VM_MEM      - VM memory in MB [$(VM_MEM)]"
	@echo "  VM_DISK_SIZE - VM disk size in GB [$(VM_DISK_SIZE)]"
	@echo "  VM_FIRMWARE - Boot firmware: bios or uefi [$(VM_FIRMWARE)]"
	@echo "  VM_KVM_PORT - KVM serial console telnet port [$(VM_KVM_PORT)]"
	@echo "  VM_SSH_PORT - Host SSH forwarding port [$(VM_SSH_PORT)]"

rootfs: $(STAMPDIR)/ubuntu-image

image: $(STAMPDIR)/image

# Download all .deb packages for staging into rootfs via image-definition copy-file
$(STAMPDIR)/download-debs: | $(STAMPDIR) $(FILES_DIR)
	$(Q)echo "==== Downloading deb packages ===="
	$(Q)echo "  Downloading libsaibcm..."
	$(Q)curl --retry 5 --retry-delay 3 --retry-all-errors -fSL -o "$(FILES_DIR)/libsaibcm.deb" "$(LIBSAIBCM_URL)"
	$(Q)curl -sL "https://ppa.launchpadcontent.net/$(PPA_NAME)/ubuntu/dists/$(SERIES)/main/binary-amd64/Packages.gz" | gunzip > $(FILES_DIR)/Packages
	$(Q)for pkg in platform-modules-s5232f opennsl-modules; do \
		relpath=$$(awk -v p="$$pkg" '$$1=="Package:" && $$2==p {f=1} f && $$1=="Filename:" {print $$2; exit}' $(FILES_DIR)/Packages); \
		echo "  Downloading $$pkg..."; \
		curl --retry 5 --retry-delay 3 --retry-all-errors -fSL -o "$(FILES_DIR)/$$pkg.deb" "$(PPA_URL)/$$relpath"; \
	done
	$(Q)rm -f $(FILES_DIR)/Packages
	$(Q)touch $@

# Step 1: Run ubuntu-image classic to build the complete rootfs tarball
$(STAMPDIR)/ubuntu-image: image-definition.yaml $(STAMPDIR)/download-debs | $(STAMPDIR) $(BUILDDIR)
	$(Q)echo "==== Building rootfs via ubuntu-image ===="
	$(Q)sudo ubuntu-image classic \
		-w "$(UI_WORKDIR)" \
		-O "$(BUILDDIR)" \
		$(UI_DEBUG) \
		image-definition.yaml
	$(Q)touch $@

# Step 2: Package into ONIE installer image
$(STAMPDIR)/image: $(STAMPDIR)/ubuntu-image | $(STAMPDIR) $(BUILDDIR)
	$(Q)echo "==== Creating ONIE installer image ===="
	$(Q)sudo ./build-onie.sh \
		--arch "$(ARCH)" \
		--bootloader "$(BOOTLOADER)" \
		--rootfs-tarball "$(BUILDDIR)/$(ROOTFS_TARBALL_NAME)" \
		--nos-name "$(NOS_NAME)" \
		--nos-version "$(NOS_VERSION)" \
		--git-branch "$(GIT_BRANCH)" \
		--git-rev "$(GIT_REV)" \
		--part-size "$(PART_SIZE_MB)" \
		--output "$(BUILDDIR)/$(IMAGE_NAME)"
	$(Q)touch $@

$(STAMPDIR):
	$(Q)mkdir -p $@

$(BUILDDIR):
	$(Q)mkdir -p $@

$(FILES_DIR):
	$(Q)mkdir -p $@

clean:
	$(Q)echo "==== Cleaning build artifacts ===="
	$(Q)sudo rm -rf $(STAMPDIR) $(UI_WORKDIR) $(FILES_DIR)
	$(Q)sudo rm -f $(BUILDDIR)/$(IMAGE_NAME) $(BUILDDIR)/*.squashfs $(BUILDDIR)/*.zip
	$(Q)sudo rm -f $(BUILDDIR)/$(ROOTFS_TARBALL_NAME)
distclean: clean
	$(Q)echo "==== Removing all build data ===="
	$(Q)sudo rm -rf $(BUILDDIR)

vm-create:
	$(Q)./test-vm.sh create \
		--onie-iso "$(ONIE_ISO)" \
		--onie-iso-url "$(ONIE_ISO_URL)" \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--mem "$(VM_MEM)" \
		--disk-size "$(VM_DISK_SIZE)" \
		--firmware "$(VM_FIRMWARE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-install:
	$(Q)./test-vm.sh install \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--installer "$(BUILDDIR)/$(IMAGE_NAME)" \
		--firmware "$(VM_FIRMWARE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-run:
	$(Q)./test-vm.sh run \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--firmware "$(VM_FIRMWARE)" \
		--mem "$(VM_MEM)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-test:
	$(Q)./test-vm.sh test \
		--onie-iso "$(ONIE_ISO)" \
		--onie-iso-url "$(ONIE_ISO_URL)" \
		--installer "$(BUILDDIR)/$(IMAGE_NAME)" \
		--disk "$(BUILDDIR)/vm/onie-disk.qcow2" \
		--mem "$(VM_MEM)" \
		--disk-size "$(VM_DISK_SIZE)" \
		--firmware "$(VM_FIRMWARE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"
