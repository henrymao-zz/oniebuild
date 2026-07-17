# ONIE build setting
NOS_NAME ?= Ubuntu
NOS_VERSION ?= 1.0.0
ARCH ?= x86_64
PART_SIZE_MB ?= 4096

GIT_BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
GIT_REV ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

SERIES ?= resolute
PPA_NAME ?= henrymao/ubuntu-nos
PPA_URL ?= https://ppa.launchpadcontent.net/$(PPA_NAME)/ubuntu
LIBSAIBCM_URL ?= https://packages.trafficmanager.net/public/sai/sai-broadcom/SAI_11.2.0_GA-202405/11.2.30.5/xgs/libsaibcm_11.2.30.5_amd64.deb

IMAGE_NAME ?= $(NOS_NAME)-$(NOS_VERSION)-$(ARCH)-installer.bin

# VM Testing Target setting
ONIE_ISO_URL ?= https://packages.trafficmanager.net/public/onie/onie-recovery-x86_64-kvm_x86_64-r0.iso
ONIE_ISO ?= build/vm/onie-recovery-x86_64-kvm_x86_64-r0.iso
VM_MEM ?= 2048
VM_DISK_SIZE ?= 40
VM_KVM_PORT ?= 9000
VM_SSH_PORT ?= 3041


.PHONY: all image vm-create vm-install vm-run vm-test clean distclean help

all: image

help:
	@echo "ONIEBuild - Build ONIE-compatible installer images"
	@echo ""
	@echo "Targets:"
	@echo "  image     - Package into ONIE installer image(default)"
	@echo "  clean     - Remove build artifacts (keep downloads)"
	@echo "  distclean - Remove everything including downloads"
	@echo ""
	@echo ""
	@echo "VM Testing Targets (require ONIE recovery ISO):"
	@echo "  vm-create   - Create KVM VM with ONIE installed from recovery ISO"
	@echo "  vm-install  - Install ONIEBuild image onto existing ONIE VM"
	@echo "  vm-run      - Boot the installed NOS image in the VM"
	@echo "  vm-test     - Full pipeline: create -> install NOS -> verify boot"
	@echo ""

image: build/stamps/image

# Download all .deb packages for staging into rootfs via image-definition copy-file
build/stamps/download-debs: | build/stamps build/debs
	$(Q)echo "==== Downloading deb packages ===="
	$(Q)echo "  Downloading libsaibcm..."
	$(Q)curl --fail -o "build/debs/libsaibcm.deb" "$(LIBSAIBCM_URL)"
	$(Q)curl -sL "https://ppa.launchpadcontent.net/$(PPA_NAME)/ubuntu/dists/$(SERIES)/main/binary-amd64/Packages.gz" | gunzip > build/debs/Packages
	$(Q)for pkg in platform-modules-s5232f opennsl-modules; do \
		relpath=$$(awk -v p="$$pkg" '$$1=="Package:" && $$2==p {f=1} f && $$1=="Filename:" {print $$2; exit}' build/debs/Packages); \
		echo "  Downloading $$pkg..."; \
		curl --fail -o "build/debs/$$pkg.deb" "$(PPA_URL)/$$relpath"; \
	done
	$(Q)rm -f build/debs/Packages
	$(Q)touch $@

# Step 1: Run ubuntu-image classic to build the complete rootfs tarball
build/stamps/ubuntu-image: image-definition.yaml build/stamps/download-debs | build/stamps build
	$(Q)echo "==== Building rootfs via ubuntu-image ===="
	$(Q)sudo ubuntu-image classic \
		-w build/.ubuntu-image \
		-O "build" \
		image-definition.yaml
	$(Q)touch $@

# Step 2: Package into ONIE installer image
build/stamps/image: build/stamps/ubuntu-image | build/stamps build
	$(Q)echo "==== Creating ONIE installer image ===="
	$(Q)./build-onie.sh \
		--arch "$(ARCH)" \
		--rootfs-tarball build/ubuntu-nos-rootfs.tar.gz \
		--nos-name "$(NOS_NAME)" \
		--nos-version "$(NOS_VERSION)" \
		--git-branch "$(GIT_BRANCH)" \
		--git-rev "$(GIT_REV)" \
		--part-size "$(PART_SIZE_MB)" \
		--output "build/$(IMAGE_NAME)"
	$(Q)touch $@

build/stamps:
	$(Q)mkdir -p $@

build:
	$(Q)mkdir -p $@

build/debs:
	$(Q)mkdir -p $@

clean:
	$(Q)echo "==== Cleaning build artifacts ===="
	$(Q)sudo rm -rf build/stamps build/.ubuntu-image build/debs
	$(Q)sudo rm -f build/$(IMAGE_NAME) build/*.squashfs build/*.zip
	$(Q)sudo rm -f build/ubuntu-nos-rootfs.tar.gz

distclean: clean
	$(Q)echo "==== Removing all build data ===="
	$(Q)sudo rm -rf build

vm-create:
	$(Q)./test-vm.sh create \
		--onie-iso "$(ONIE_ISO)" \
		--onie-iso-url "$(ONIE_ISO_URL)" \
		--disk "build/vm/onie-disk.qcow2" \
		--mem "$(VM_MEM)" \
		--disk-size "$(VM_DISK_SIZE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-install:
	$(Q)./test-vm.sh install \
		--disk "build/vm/onie-disk.qcow2" \
		--installer "build/$(IMAGE_NAME)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-run:
	$(Q)./test-vm.sh run \
		--disk "build/vm/onie-disk.qcow2" \
		--mem "$(VM_MEM)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"

vm-test:
	$(Q)./test-vm.sh test \
		--onie-iso "$(ONIE_ISO)" \
		--onie-iso-url "$(ONIE_ISO_URL)" \
		--installer "build/$(IMAGE_NAME)" \
		--disk "build/vm/onie-disk.qcow2" \
		--mem "$(VM_MEM)" \
		--disk-size "$(VM_DISK_SIZE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)"