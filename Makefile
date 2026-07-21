# ONIE build configuration
NOS_NAME ?= Ubuntu
NOS_VERSION ?= 1.0.0
ARCH ?= x86_64
PART_SIZE_MB ?= 4096

GIT_BRANCH ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
GIT_REV ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

PPA_NAME ?= henrymao/ubuntu-nos
LIBSAIBCM_URL ?= https://packages.trafficmanager.net/public/sai/sai-broadcom/SAI_11.2.0_GA-202405/11.2.30.5/xgs/libsaibcm_11.2.30.5_amd64.deb

IMAGE_NAME ?= $(NOS_NAME)-$(NOS_VERSION)-$(ARCH)-installer.bin

# VM testing configuration
ONIE_ISO_URL ?= https://packages.trafficmanager.net/public/onie/onie-recovery-x86_64-kvm_x86_64-r0.iso
ONIE_ISO ?= build/vm/onie-recovery-x86_64-kvm_x86_64-r0.iso
VM_DISK ?= build/vm/onie-disk.qcow2
VM_MEM ?= 2048
VM_DISK_SIZE ?= 40
VM_KVM_PORT ?= 9000
VM_SSH_PORT ?= 3041

.PHONY: all clean help image download-debs vm-create vm-install vm-run vm-test

all: image  # Build the ONIE installer image (default)

# --------------------------------------------------------------------------
# Help
# --------------------------------------------------------------------------
help:  # Display this help
	@echo "Usage: make [target]\n"
	@echo "Targets:"
	@awk -F'#' '/^[a-z0-9-]+:/ { sub(":.*", "", $$1); if ($$2 != "") print " ", $$1, "#", $$2 }' Makefile | column -t -s '#'

# --------------------------------------------------------------------------
# Build pipeline (artifact-based, incremental)
# --------------------------------------------------------------------------
image: build/$(IMAGE_NAME)  # Build the ONIE installer image

# Download platform .deb packages for staging into the rootfs.
download-debs: build/debs/libsaibcm.deb build/debs/opennsl-modules.deb build/debs/platform-modules-s5232f.deb

build/debs/libsaibcm.deb:
	mkdir -p build/debs
	curl --fail -o $@ "$(LIBSAIBCM_URL)"

build/debs/opennsl-modules.deb build/debs/platform-modules-s5232f.deb &:
	mkdir -p build/debs
	sudo add-apt-repository -y ppa:$(PPA_NAME)
	sudo apt-get update -qq
	cd build/debs && apt-get download opennsl-modules platform-modules-s5232f
	mv build/debs/opennsl-modules_*.deb build/debs/opennsl-modules.deb
	mv build/debs/platform-modules-s5232f_*.deb build/debs/platform-modules-s5232f.deb

# Build rootfs tarball via ubuntu-image classic.
build/ubuntu-nos-rootfs.tar.gz: image-definition.yaml build/debs/libsaibcm.deb build/debs/opennsl-modules.deb build/debs/platform-modules-s5232f.deb
	@mkdir -p build
	echo "==== Building rootfs via ubuntu-image ===="
	sudo ubuntu-image classic -w build/.ubuntu-image -O build image-definition.yaml

# Package rootfs tarball into the ONIE self-extracting installer.
build/$(IMAGE_NAME): build/ubuntu-nos-rootfs.tar.gz
	@mkdir -p build
	echo "==== Creating ONIE installer image ===="
	./build-onie.sh \
		--arch "$(ARCH)" \
		--rootfs-tarball build/ubuntu-nos-rootfs.tar.gz \
		--nos-name "$(NOS_NAME)" \
		--nos-version "$(NOS_VERSION)" \
		--git-branch "$(GIT_BRANCH)" \
		--git-rev "$(GIT_REV)" \
		--part-size "$(PART_SIZE_MB)" \
		--output "build/$(IMAGE_NAME)"

# --------------------------------------------------------------------------
# Cleanup
# --------------------------------------------------------------------------
clean:  # Remove everything including build dir and VM disks
	sudo rm -rf build

# --------------------------------------------------------------------------
# VM testing (require ONIE recovery ISO; auto-downloaded if absent)
# --------------------------------------------------------------------------
vm-create:  # Create KVM VM with ONIE installed from recovery ISO
	./test-vm.sh create \
		--onie-iso "$(ONIE_ISO)" \
		--onie-iso-url "$(ONIE_ISO_URL)" \
		--disk "$(VM_DISK)" \
		--mem "$(VM_MEM)" \
		--disk-size "$(VM_DISK_SIZE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)" $(ARGS)

vm-install:  # Install ONIE image onto an existing ONIE VM
	./test-vm.sh install \
		--disk "$(VM_DISK)" \
		--installer "build/$(IMAGE_NAME)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)" $(ARGS)

vm-run:  # Boot the installed NOS image interactively
	./test-vm.sh run \
		--disk "$(VM_DISK)" \
		--mem "$(VM_MEM)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)" $(ARGS)

vm-test:  # Full pipeline: create -> install NOS -> verify boot
	./test-vm.sh test \
		--onie-iso "$(ONIE_ISO)" \
		--onie-iso-url "$(ONIE_ISO_URL)" \
		--installer "build/$(IMAGE_NAME)" \
		--disk "$(VM_DISK)" \
		--mem "$(VM_MEM)" \
		--disk-size "$(VM_DISK_SIZE)" \
		--kvm-port "$(VM_KVM_PORT)" \
		--ssh-port "$(VM_SSH_PORT)" $(ARGS)
