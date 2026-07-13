#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

MEM="${VM_MEM:-2048}"
DISK_SIZE="${VM_DISK_SIZE:-40}"
KVM_PORT="${VM_KVM_PORT:-9000}"
VNC_PORT="${VM_VNC_PORT:-0}"
SSH_FWD_PORT="${VM_SSH_PORT:-3041}"
FIRMWARE="${VM_FIRMWARE:-bios}"
ONIE_ISO_URL="${ONIE_ISO_URL:-}"
DISK=""
ONIE_ISO=""
INSTALLER=""
OUTPUT_DISK=""
ONIE_MODE="install"
TIMEOUT_INSTALL="${VM_INSTALL_TIMEOUT:-600}"
TIMEOUT_BOOT="${VM_BOOT_TIMEOUT:-240}"
ONIE_BASE_DISK=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  create     Create a KVM VM disk with ONIE installed (from recovery ISO)
  install    Install ONIE image onto an existing ONIE VM
  run        Boot the installed NOS image
  test       Full pipeline: create VM -> install ONIE -> install NOS -> verify boot

Options:
  --disk PATH          VM disk image path (default: build/vm/onie-disk.qcow2)
  --onie-iso PATH      ONIE recovery ISO for KVM (auto-downloaded if not set)
  --onie-iso-url URL   URL to download ONIE recovery ISO (default: $ONIE_ISO_URL)
  --installer PATH     ONIE installer .bin file (required for install/test)
  --output PATH        Output disk path after install (default: build/vm/nos-disk.qcow2)
  --firmware MODE      BIOS mode: bios or uefi (default: $FIRMWARE)
  --mem MB             VM memory in MB (default: $MEM)
  --disk-size GB       VM disk size in GB (default: $DISK_SIZE)
  --kvm-port PORT     Telnet port for serial console (default: $KVM_PORT)
  --ssh-port PORT     Host SSH forwarding port (default: $SSH_FWD_PORT)
  --timeout-install S  Install timeout in seconds (default: $TIMEOUT_INSTALL)
  --timeout-boot S     Boot timeout in seconds (default: $TIMEOUT_BOOT)

Examples:
  # Build ONIE image first, then test in a VM:
  $(basename "$0") test --onie-iso /path/to/onie-recovery-x86_64-kvm_x86_64-r0.iso

  # Step by step:
  $(basename "$0") create --onie-iso /path/to/onie-recovery-x86_64-kvm_x86_64-r0.iso
  $(basename "$0") install --installer build/ONIE-1.0.0-x86_64-installer.bin
  $(basename "$0") run

  # UEFI boot:
  $(basename "$0") test --onie-iso /path/to/onie-recovery.iso --firmware uefi
EOF
    exit "${1:-0}"
}

parse_args() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        create|install|run|test) ONIE_MODE="$cmd" ;;
        -h|--help) usage 0 ;;
        "") usage 1 ;;
        *) echo "ERROR: Unknown command: $cmd"; usage 1 ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk) DISK="$2"; shift 2 ;;
            --onie-iso) ONIE_ISO="$2"; shift 2 ;;
            --onie-iso-url) ONIE_ISO_URL="$2"; shift 2 ;;
            --installer) INSTALLER="$2"; shift 2 ;;
            --output) OUTPUT_DISK="$2"; shift 2 ;;
            --firmware) FIRMWARE="$2"; shift 2 ;;
            --mem) MEM="$2"; shift 2 ;;
            --disk-size) DISK_SIZE="$2"; shift 2 ;;
            --kvm-port) KVM_PORT="$2"; shift 2 ;;
            --ssh-port) SSH_FWD_PORT="$2"; shift 2 ;;
            --timeout-install) TIMEOUT_INSTALL="$2"; shift 2 ;;
            --timeout-boot) TIMEOUT_BOOT="$2"; shift 2 ;;
            --onie-base-disk) ONIE_BASE_DISK="$2"; shift 2 ;;
            -h|--help) usage 0 ;;
            *) echo "ERROR: Unknown option: $1"; usage 1 ;;
        esac
    done

    VM_DIR="$PROJECT_DIR/build/vm"
    mkdir -p "$VM_DIR"

    : "${DISK:=$VM_DIR/onie-disk.qcow2}"
    : "${OUTPUT_DISK:=$VM_DIR/nos-disk.qcow2}"
    : "${ONIE_BASE_DISK:=$VM_DIR/onie-base.qcow2}"

    if [[ "$ONIE_MODE" == "create" || "$ONIE_MODE" == "test" ]]; then
        if [[ -z "${ONIE_ISO:-}" ]]; then
            ONIE_ISO="$VM_DIR/$(basename "$ONIE_ISO_URL")"
        fi
        if [[ ! -f "$ONIE_ISO" ]]; then
            echo "ONIE recovery ISO not found: $ONIE_ISO"
            echo "Downloading from: $ONIE_ISO_URL"
            curl -fSL -o "$ONIE_ISO" "$ONIE_ISO_URL"
            if [[ ! -f "$ONIE_ISO" ]]; then
                echo "ERROR: Failed to download ONIE recovery ISO"
                exit 1
            fi
            echo "Download complete: $ONIE_ISO"
        fi
        ONIE_ISO="$(readlink -f "$ONIE_ISO")"
    fi

    if [[ "$ONIE_MODE" == "install" || "$ONIE_MODE" == "test" ]]; then
        if [[ -z "${INSTALLER:-}" ]]; then
            INSTALLER=$(ls -t "$PROJECT_DIR"/build/*-installer.bin 2>/dev/null | head -1)
            if [[ -z "$INSTALLER" ]]; then
                echo "ERROR: No installer .bin found. Build with 'make image' or specify --installer"
                exit 1
            fi
        fi
        INSTALLER="$(readlink -f "$INSTALLER")"
        if [[ ! -f "$INSTALLER" ]]; then
            echo "ERROR: Installer not found: $INSTALLER"
            exit 1
        fi
    fi
}

check_deps() {
    local missing=()

    command -v qemu-system-x86_64 >/dev/null 2>&1 || missing+=(qemu-system-x86_64)
    command -v qemu-img >/dev/null 2>&1 || missing+=(qemu-img)
    command -v expect >/dev/null 2>&1 || missing+=(expect)

    if [[ "$FIRMWARE" == "uefi" ]]; then
        if [[ ! -f /usr/share/OVMF/OVMF_CODE.fd ]] && [[ ! -f /usr/share/edk2/ovmf/OVMF_CODE.fd ]] && [[ ! -f /usr/share/qemu/OVMF.fd ]]; then
            missing+=("OVMF firmware (install: sudo apt install ovmf)")
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies:"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        echo ""
        echo "Install with: sudo apt install qemu-system-x86 qemu-utils expect ovmf"
        exit 1
    fi
}

get_ovmf_path() {
    for f in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF.fd; do
        if [[ -f "$f" ]]; then
            echo "$f"
            return
        fi
    done
    echo ""
}

create_disk() {
    echo "Creating VM disk: $DISK (${DISK_SIZE}GB)"
    qemu-img create -f qcow2 "$DISK" "${DISK_SIZE}G"
}

prepare_installer_disk() {
    local installer_disk="$VM_DIR/installer.img"

    echo "Preparing installer disk with: $(basename "$INSTALLER")" >&2
    fallocate -l 5120M "$installer_disk"

    sudo parted -s "$installer_disk" mklabel msdos
    sudo parted -s "$installer_disk" mkpart primary fat32 1MiB 100%
    sudo parted -s "$installer_disk" set 1 boot on

    local offset=$((2048 * 512))

    if ! mformat -i "$installer_disk@@$offset" -v ONIEINST :: 2>/dev/null; then
        local loop_dev
        loop_dev=$(sudo losetup --show -fP "$installer_disk")
        INSTALLER_LOOP_DEV="$loop_dev"

        sudo mkfs.vfat -F 32 "${loop_dev}p1" >/dev/null 2>&1

        local tmpdir
        tmpdir=$(mktemp -d)
        sudo mount "${loop_dev}p1" "$tmpdir"
        sudo cp "$INSTALLER" "$tmpdir/onie-installer.bin"
        sudo chmod +x "$tmpdir/onie-installer.bin"

        sudo umount "$tmpdir"
        sudo losetup -d "$loop_dev"
        INSTALLER_LOOP_DEV=""
        rm -rf "$tmpdir"
    else
        mcopy -i "$installer_disk@@$offset" "$INSTALLER" ::onie-installer.bin
    fi

    echo "$installer_disk"
}

start_kvm() {
    local boot_order="$1"
    shift
    local extra_args=("$@")

    local bios_arg=()
    if [[ "$FIRMWARE" == "uefi" ]]; then
        local ovmf
        ovmf=$(get_ovmf_path)
        if [[ -n "$ovmf" ]]; then
            bios_arg=(-bios "$ovmf")
        fi
    fi

    local cdrom_arg=()
    if [[ "${ONIE_ISO:-}" && "$boot_order" == cd* ]]; then
        cdrom_arg=(-cdrom "$ONIE_ISO")
    fi

    local disk_arg=(-drive "file=$DISK,media=disk,if=virtio,index=0")

    echo "Starting KVM VM (mem=${MEM}MB, firmware=${FIRMWARE}, serial=telnet:$KVM_PORT)..."

    qemu-system-x86_64 \
        -m "$MEM" \
        -name "onie" \
        -boot "order=$boot_order" \
        "${bios_arg[@]}" \
        "${cdrom_arg[@]}" \
        "${disk_arg[@]}" \
        "${extra_args[@]}" \
        -device e1000,netdev=onienet \
        -netdev "user,id=onienet,hostfwd=tcp:127.0.0.1:${SSH_FWD_PORT}-:22" \
        -vnc "127.0.0.1:$VNC_PORT" \
        -vga std \
        -serial "telnet:127.0.0.1:$KVM_PORT,server" \
        -monitor none \
        > "$VM_DIR/kvm.log" 2>&1 &

    KVM_PID=$!
    echo "KVM PID: $KVM_PID"
}

wait_for_kvm() {
    local count=30
    local wait_sec=2
    for ((i = 1; i <= count; i++)); do
        sleep "$wait_sec"
        if [[ -d "/proc/$KVM_PID" ]]; then
            if nc -z 127.0.0.1 "$KVM_PORT" 2>/dev/null; then
                echo "KVM serial console ready on port $KVM_PORT"
                return 0
            fi
        else
            # Check if QEMU exited with the wait_kvm_ready check
            # It may have rebooted and needs a moment
            sleep 1
            if [[ -d "/proc/$KVM_PID" ]]; then
                continue
            fi
            echo "ERROR: KVM process died"
            cat "$VM_DIR/kvm.log" 2>/dev/null || true
            return 1
        fi
    done
    echo "ERROR: KVM did not start within timeout"
    return 1
}

kill_kvm() {
    if [[ -n "${KVM_PID:-}" ]] && [[ -d "/proc/$KVM_PID" ]]; then
        echo "Stopping KVM (PID: $KVM_PID)..."
        kill "$KVM_PID" 2>/dev/null || true
        wait "$KVM_PID" 2>/dev/null || true
        KVM_PID=""
    fi
}

on_exit() {
    kill_kvm
    if [[ -n "${INSTALLER_LOOP_DEV:-}" ]]; then
        sudo umount "${INSTALLER_LOOP_DEV}p1" 2>/dev/null || true
        sudo losetup -d "$INSTALLER_LOOP_DEV" 2>/dev/null || true
    fi
}

trap on_exit EXIT

install_onie_via_expect() {
    echo "Installing ONIE via serial console (selecting 'embed' from GRUB menu)..."

    expect <<EXPECT_EOF
set timeout 300
spawn telnet 127.0.0.1 $KVM_PORT

# Wait for GRUB menu and select "Embed ONIE"
expect {
    "The highlighted entry will be executed" {
        send "\x1b\[B"
        expect {
            "ONIE: Embed ONIE" {
                send "\r"
            }
            "The highlighted entry will be executed" {
                send "\x1b\[B"
                exp_continue
            }
            timeout {
                send "\r"
            }
        }
    }
    timeout {
        puts "ERROR: Timed out waiting for GRUB menu"
        exit 1
    }
}

# Wait for ONIE console to appear (updater runs in background)
expect {
    "Please press Enter to activate this console" {
        puts ">>> ONIE console ready, updater running in background"
    }
    timeout {
        puts "ERROR: Timed out waiting for ONIE console"
        exit 1
    }
}

send "\r"
expect -re {[#\$] }

# Monitor the onie log for updater completion
puts ">>> Waiting for ONIE updater to finish installing to disk..."
send "tail -f /var/log/onie.log\r"

expect {
    "ONIE: Success: Firmware update" {
        puts ">>> ONIE updater completed successfully"
    }
    "ONIE: Rebooting" {
        puts ">>> ONIE updater done, rebooting"
    }
    timeout {
        puts "WARNING: Timed out waiting for updater completion, checking status..."
    }
}

# Stop tail and verify
send "\x03"
expect -re {[#\$] }
send "fdisk -l /dev/vda 2>/dev/null | grep -c vda; echo PART_CHECK\r"
expect "PART_CHECK"
expect -re {[#\$] }

send "poweroff\r"
expect eof
EXPECT_EOF

    echo "ONIE installation to disk complete."
}

trigger_onie_install() {
    echo "Triggering ONIE install mode (manual installer execution)..."

    expect <<EXPECT_EOF
set timeout 300
spawn telnet 127.0.0.1 $KVM_PORT

# Step 1: Get through GRUB menu to ONIE console
expect {
    "The highlighted entry will be executed" {
        send "\r"
    }
    timeout {
        puts "ERROR: Timed out waiting for GRUB menu"
        exit 1
    }
}

# Step 2: Wait for ONIE boot prompt and activate console
expect {
    "Please press Enter to activate this console" {
        puts ">>> ONIE console detected"
        send "\r"
        sleep 2
    }
    -re {[#\$] } {
        puts ">>> Already at shell prompt"
    }
    timeout {
        puts "ERROR: Timed out waiting for ONIE console"
        exit 1
    }
}

# Step 3: Kill ONIE discovery (runs background TFTP attempts)
puts ">>> Stopping ONIE discovery..."
send "killall discover 2>/dev/null; sleep 1\r"

# Wait for clean shell prompt
expect {
    -re {[#\$] } {
        puts ">>> Shell prompt ready"
    }
    timeout {
        puts "WARNING: No shell prompt after killall, retrying..."
        send "\r"
        sleep 1
        send "killall discover 2>/dev/null; sleep 1\r"
        expect {
            -re {[#\$] } {
                puts ">>> Shell prompt ready (retry)"
            }
            timeout {
                puts "ERROR: Timed out waiting for ONIE shell prompt"
                exit 1
            }
        }
    }
}

send "mkdir -p /mnt/vdb\r"
expect -re {[#\$] }

puts ">>> Mounting installer disk..."
send "mount /dev/vdb1 /mnt/vdb || mount /dev/vdb /mnt/vdb\r"
expect {
    -re {[#\$] } {
        puts ">>> Mount completed"
    }
    timeout {
        puts "ERROR: Could not mount installer disk"
        exit 1
    }
}

send "ls /mnt/vdb/\r"
expect -re {[#\$] }

puts ">>> Running ONIE installer..."
send "chmod +x /mnt/vdb/onie-installer.bin && /mnt/vdb/onie-installer.bin\r"

set timeout $TIMEOUT_INSTALL
expect {
    "Installation complete" {
        puts ">>> NOS installation succeeded"
    }
    "ONIE: Executing installer" {
        puts ">>> Installer started..."
        exp_continue
    }
    "Verifying image checksum" {
        puts ">>> Installer checksum verified"
        exp_continue
    }
    "Preparing image archive" {
        puts ">>> Installer archive prepared"
        exp_continue
    }
    "Error: Unable" {
        puts "ERROR: Installer reported an error"
        exit 1
    }
    timeout {
        puts "ERROR: Installer timed out after $TIMEOUT_INSTALL seconds"
        exit 1
    }
}

catch {send "\r"} result
catch {expect -re {[#\$] }} result
catch {send "poweroff\r"} result
catch {expect eof} result
EXPECT_EOF

    echo "NOS installation complete."
}

verify_boot() {
    echo "Booting installed NOS and verifying..."

    expect <<EXPECT_EOF
set timeout $TIMEOUT_BOOT
spawn telnet 127.0.0.1 $KVM_PORT

expect {
    "login:" {
        puts ">>> NOS booted successfully - login prompt detected"
    }
    timeout {
        puts "ERROR: Timed out waiting for NOS boot"
        exit 1
    }
}

send "admin\r"

expect {
    "Password:" {
        send "admin\r"
        expect -re {[#\$] }
        puts ">>> Logged in as admin"
    }
    timeout {
        puts "ERROR: Could not login"
        exit 1
    }
}

send "sudo cat /etc/os-release\r"
expect -re {[#\$] }

send "uptime\r"
expect -re {[#\$] }

send "uname -a\r"
expect -re {[#\$] }

send "sudo ip addr show\r"
expect -re {[#\$] }

send "sudo systemctl is-active systemd-logind\r"
expect -re {[#\$] }

puts ">>> NOS verification PASSED"

catch {send "poweroff\r"} result
catch {expect eof} result
EXPECT_EOF

    echo "NOS verification complete."
}

do_create() {
    echo "========================================="
    echo " Step 1: Create VM with ONIE installed"
    echo "========================================="

    if [[ -f "$DISK" ]]; then
        echo "Removing existing disk: $DISK"
        rm -f "$DISK"
    fi

    create_disk

    start_kvm "cd"
    wait_for_kvm

    install_onie_via_expect

    kill_kvm
    sleep 2

    echo "ONIE VM disk created: $DISK"
    echo ""
    echo "Next steps:"
    echo "  $(basename "$0") install --installer <path-to-installer.bin>"
    echo "  Or run the full test:"
    echo "  $(basename "$0") test --onie-iso $ONIE_ISO --installer <path-to-installer.bin>"
}

do_install() {
    echo "========================================="
    echo " Step 2: Install NOS image onto ONIE VM"
    echo "========================================="

    if [[ ! -f "$DISK" ]]; then
        echo "ERROR: ONIE VM disk not found: $DISK"
        echo "Run '$(basename "$0") create' first"
        exit 1
    fi

    local installer_disk
    installer_disk=$(prepare_installer_disk)

    start_kvm "c" \
        -drive "file=$installer_disk,if=virtio,index=1,format=raw"
    wait_for_kvm

    trigger_onie_install

    kill_kvm
    sleep 2

    if [[ "$DISK" != "$OUTPUT_DISK" ]]; then
        echo "Copying installed disk to: $OUTPUT_DISK"
        cp "$DISK" "$OUTPUT_DISK"
    fi

    echo "NOS installed to VM disk: $DISK"
    echo ""
    echo "Boot the NOS with:"
    echo "  $(basename "$0") run"
}

do_run() {
    echo "========================================="
    echo " Boot NOS image"
    echo "========================================="

    if [[ ! -f "$DISK" ]]; then
        echo "ERROR: VM disk not found: $DISK"
        exit 1
    fi

    echo "Booting NOS VM..."
    echo "  SSH: ssh admin@localhost -p $SSH_FWD_PORT"
    echo "  Serial: telnet 127.0.0.1 $KVM_PORT"
    echo "  VNC: vncviewer :$VNC_PORT"
    echo "  Press Ctrl+C to stop"

    start_kvm "c"
    wait_for_kvm

    echo "VM is running. Press Ctrl+C to stop."
    wait "$KVM_PID" 2>/dev/null || true
}

do_test() {
    echo "========================================="
    echo " Full Test Pipeline"
    echo "========================================="
    echo "  ONIE ISO:      $(basename "${ONIE_ISO:-N/A}")"
    echo "  Installer:     $(basename "${INSTALLER:-N/A}")"
    echo "  Firmware:      $FIRMWARE"
    echo "  Memory:        ${MEM}MB"
    echo "  Disk:          ${DISK_SIZE}GB"
    echo "  Target disk:   $DISK"
    echo "========================================="

    if [[ -f "$DISK" ]]; then
        echo "Removing existing disk: $DISK"
        rm -f "$DISK"
    fi

    create_disk

    echo ""
    echo "--- Phase 1: Install ONIE to disk ---"
    start_kvm "cd"
    wait_for_kvm
    install_onie_via_expect
    kill_kvm
    sleep 2

    echo "Saving clean ONIE base disk: $ONIE_BASE_DISK"
    cp "$DISK" "$ONIE_BASE_DISK"

    echo ""
    echo "--- Phase 2: Install NOS via ONIE ---"
    local installer_disk
    installer_disk=$(prepare_installer_disk)

    start_kvm "c" \
        -drive "file=$installer_disk,if=virtio,index=1,format=raw"
    wait_for_kvm
    trigger_onie_install
    kill_kvm
    sleep 2

    if [[ "$DISK" != "$OUTPUT_DISK" ]]; then
        cp "$DISK" "$OUTPUT_DISK"
    fi

    echo ""
    echo "--- Phase 3: Boot and verify NOS ---"
    start_kvm "c"
    wait_for_kvm
    verify_boot
    kill_kvm
    sleep 2

    echo ""
    echo "========================================="
    echo " Test PASSED"
    echo "========================================="
    echo "  VM disk: $DISK"
    echo "  Boot with: $(basename "$0") run"
    echo "  SSH:      ssh admin@localhost -p $SSH_FWD_PORT"
}

parse_args "$@"
check_deps

case "$ONIE_MODE" in
    create) do_create ;;
    install) do_install ;;
    run) do_run ;;
    test) do_test ;;
esac
