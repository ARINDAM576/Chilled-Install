#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/chilled-lab}"

# Locate the CachyOS ISO (checks ~/Downloads first, or specify full path)
ISO_PATH=$(find "$HOME/Downloads" -maxdepth 1 -name "cachyos-*.iso" | head -n 1)

if [[ -z "$ISO_PATH" || ! -f "$ISO_PATH" ]]; then
    echo "Error: Could not automatically find cachyos-*.iso in $HOME/Downloads."
    echo "Please set ISO_PATH manually in scripts/lab-boot.sh."
    exit 1
fi

echo "==> Using ISO: $ISO_PATH"

# Locate OVMF Code
OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
if [[ ! -f "$OVMF_CODE" ]]; then
    OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.fd"
fi

QEMU_ARGS=(
    -enable-kvm
    -machine q35
    -cpu host
    -smp 4
    -m 4096
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$LAB_DIR/OVMF_VARS.fd"
    -drive file="$LAB_DIR/host.img",format=raw,if=none,id=host
    -device nvme,drive=host,serial=hostdisk
    -device qemu-xhci
    -drive file="$LAB_DIR/stick.img",format=raw,if=none,id=stick
    -device usb-storage,drive=stick,removable=on
    # -cdrom "$ISO_PATH"
    -nic user,model=virtio-net-pci
    -device virtio-vga
    -display gtk
)

qemu-system-x86_64 "${QEMU_ARGS[@]}"
