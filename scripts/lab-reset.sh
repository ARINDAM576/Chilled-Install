#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/chilled-lab}"
LOOP=""

cleanup() {
    if [[ -n "$LOOP" ]]; then
        sudo losetup -d "$LOOP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null || { echo "missing: $1 (package: $2)"; exit 1; }; }
need sgdisk gptfdisk
need mkntfs ntfsprogs
need mkfs.fat dosfstools
need qemu-img qemu-full

if pgrep -f "qemu-system.*$LAB_DIR" >/dev/null; then
    echo "Error: a QEMU VM is currently running in $LAB_DIR. Power it off first."
    exit 1
fi

mkdir -p "$LAB_DIR"
cd "$LAB_DIR"

echo "==> Recreating disk images..."
rm -f host.img stick.img
qemu-img create -f raw host.img 20G
qemu-img create -f raw stick.img 4G

echo "==> Partitioning and formatting host.img..."
LOOP=$(sudo losetup -fP --show host.img)
sudo sgdisk -n1:0:+300M -t1:ef00 -n2:0:0 -t2:0700 "$LOOP"
sudo partprobe "$LOOP"

sudo mkfs.fat -F32 -n HOSTESP "${LOOP}p1"
sudo mkntfs -f -L HOSTWIN "${LOOP}p2"

echo "==> Verifying partition layout:"
lsblk -f "$LOOP"

sudo losetup -d "$LOOP"
LOOP=""

echo "==> Resetting OVMF variables..."
if [[ -f "/usr/share/edk2/x64/OVMF_VARS.4m.fd" ]]; then
    cp "/usr/share/edk2/x64/OVMF_VARS.4m.fd" "$LAB_DIR/OVMF_VARS.fd"
elif [[ -f "/usr/share/edk2/x64/OVMF_VARS.fd" ]]; then
    cp "/usr/share/edk2/x64/OVMF_VARS.fd" "$LAB_DIR/OVMF_VARS.fd"
elif [[ -f "/usr/share/ovmf/x64/OVMF_VARS.fd" ]]; then
    cp "/usr/share/ovmf/x64/OVMF_VARS.fd" "$LAB_DIR/OVMF_VARS.fd"
elif [[ -f "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd" ]]; then
    cp "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd" "$LAB_DIR/OVMF_VARS.fd"
else
    echo "Warning: No pristine OVMF_VARS template found in standard paths. Skipping NVRAM reset."
fi

echo "==> Lab environment successfully reset."
