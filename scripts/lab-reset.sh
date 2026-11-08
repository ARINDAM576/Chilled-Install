#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/chilled-lab}"
LOOP=""

cleanup() { if [[ -n "$LOOP" ]]; then sudo losetup -d "$LOOP" || true; fi; }
trap cleanup EXIT

need() { command -v "$1" >/dev/null || { echo "missing: $1 (package: $2)"; exit 1; }; }
need sgdisk gptfdisk
need mkntfs ntfsprogs
need mkfs.fat dosfstools
need qemu-img qemu-full

if pgrep -f "qemu-system.*$LAB_DIR" >/dev/null; then echo "a VM is running"; exit 1; fi

# TODO: delete and recreate host.img and stick.img (only inside $LAB_DIR)
# TODO: attach with losetup, partition, format, check with lsblk -f
# TODO: reset OVMF_VARS.fd from the pristine copy
