#!/usr/bin/env bash

qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=$HOME/chilled-lab/OVMF_VARS.fd \
  -drive file=$HOME/chilled-lab/host.img,format=raw,if=none,id=host \
  -device nvme,drive=host,serial=hostdisk \
  -device qemu-xhci \
  -drive file=$HOME/chilled-lab/stick.img,format=raw,if=none,id=stick \
  -device usb-storage,drive=stick,removable=on \
  # -cdrom $HOME/Downloads/cachyos-desktop-linux-260809.iso \
  -nic user,model=virtio-net-pci -device virtio-vga -display gtk
