# Manual flow (lab log)

Working log of the manual install flow, reproduced step by step in a VM lab. This is the source for the v0.1 milestone and for the scripts in v0.2.

**Status:** steps 1 to 7 done (verification reported correct; raw outputs not captured). Step 8, the clean run, is next.

> Everything below is a record of what was run and what was observed. A step is only marked as verified when it was actually run and the result was checked. Commands are not guaranteed to work on other hardware, distros or versions.

## Environment

Fill these in, since results depend on them.

| Item | Value |
|---|---|
| Host OS (lab machine) | CachyOS, Hyprland |
| Host shell | fish (scripts must use a `#!/usr/bin/env bash` shebang) |
| Host RAM | 8 GB (VM gets 4 GB) |
| QEMU version | 11.1.3 |
| OVMF / edk2 version | 202608-1 |
| Guest ISO | CachyOS desktop ISO, version/date: 260809 |

## Host tool dependencies found so far

These were missing on a normal desktop install and caused failures. The tool's preflight should check for each command and name the package to install.

| Needed command | Package (Arch) | Used for |
|---|---|---|
| `sgdisk` | `gptfdisk` | partitioning the lab disks |
| `mkfs.ntfs` / `mkntfs` | `ntfsprogs` (pulled in as optional dependency of `ntfs-3g`) | formatting the lab NTFS volume |
| `qemu-system-x86_64`, `qemu-img` | `qemu-full` | the lab VM |
| OVMF firmware files | `edk2-ovmf` | UEFI in the VM |
| `qemu-nbd` | `qemu-img` (inside the live session) | exposing the image as a disk |

Lesson: pasting a block of commands keeps going after one fails (`sgdisk` failed, then `mkfs.fat` ran against partitions that did not exist). Scripts need `set -euo pipefail`.

## Clean run: the commands that worked, in order

Consolidated from steps 2 to 7, for repeating the flow from scratch (step 8). Run the lab-host commands in bash, not fish. Every code block here is unindented so it can be pasted safely. Paste heredocs one at a time, and expect `>` at the start of each line while one is being pasted.

Prerequisites on the lab host: `gptfdisk`, `ntfs-3g`, `ntfsprogs`, `dosfstools`, `qemu-full`, `edk2-ovmf`, and the CachyOS desktop ISO.

### A. Lab host: fresh disks and firmware variables

This deletes the old lab disks. Only run it in the lab folder. Deleting first keeps the peak disk use the same as on the first run.

```
mkdir -p ~/chilled-lab && cd ~/chilled-lab
rm -f host.img stick.img
qemu-img create -f raw host.img 20G
qemu-img create -f raw stick.img 4G
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd OVMF_VARS.fd
LOOP=$(sudo losetup -fP --show host.img); echo $LOOP
sudo sgdisk -n1:0:+300M -t1:ef00 -n2:0:0 -t2:0700 $LOOP
sudo partprobe $LOOP
lsblk $LOOP
sudo mkfs.fat -F32 -n HOSTESP ${LOOP}p1
sudo mkntfs -f -L HOSTWIN ${LOOP}p2
lsblk -f $LOOP
sudo losetup -d $LOOP
```

Expected: `loop0p1` about 300M (`vfat`, label HOSTESP) and `loop0p2` about 19.7G (`ntfs`, label HOSTWIN).

### B. Boot the live ISO in the VM

Run the QEMU command from step 3 (`scripts/lab-boot.sh`), with the `-cdrom` line pointing at the ISO.

### C. In the VM's live session: image, nbd, partition table, stick

```
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL
sudo mkdir -p /mnt/win
sudo mount -t ntfs3 -o rw,noatime /dev/nvme0n1p2 /mnt/win
sudo dd if=/dev/zero of=/mnt/win/chilled.img bs=1M count=12288 status=progress
sudo pacman -Sy --needed qemu-img
sudo modprobe nbd max_part=8
sudo qemu-nbd --format=raw --cache=writethrough --connect=/dev/nbd0 /mnt/win/chilled.img
sudo parted -s /dev/nbd0 mklabel gpt mkpart root ext4 1MiB 100%
sudo partprobe /dev/nbd0
lsblk /dev/nbd0
```

Before preparing the stick, check that `sda` is the 4G USB disk and that this prints nothing:

```
findmnt | grep sda
```

Then:

```
sudo parted -s /dev/sda mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
sudo partprobe /dev/sda
sudo mkfs.fat -F32 -n CHILLEDBOOT /dev/sda1
```

### D. The installer

Close and relaunch the installer after the commands above so it rescans disks. `/dev/nbd0` must appear in the Storage device dropdown.

- Partitions, manual: `/dev/nbd0p1` mounted at `/`, ext4, format. `/dev/sda1` mounted at `/boot`, FAT32, esp flag. Do not touch `nvme0n1`.
- Bootloader: systemd-boot.
- Desktop: Xfce.
- Untick "Restart now" at the end.

### E. After the install: hook, drop-in, rebuild, fallback, unmount

```
sudo mkdir -p /mnt/cachy
sudo mount /dev/nbd0p1 /mnt/cachy
sudo mount /dev/sda1 /mnt/cachy/boot
NTFS_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p2); echo $NTFS_UUID
sudo mkdir -p /mnt/cachy/etc/initcpio/{install,hooks}
```

```
sudo tee /mnt/cachy/etc/initcpio/install/ntfsloop >/dev/null <<'EOF'
build() {
    add_module loop
    add_module ntfs3
    add_binary losetup
    add_runscript
}
help() { echo "Boot root from a partitioned image file on an NTFS volume"; }
EOF
```

```
sudo tee /mnt/cachy/etc/initcpio/hooks/ntfsloop >/dev/null <<'EOF'
#!/usr/bin/ash
run_hook() {
    mount_handler=ntfsloop_mount
}
ntfsloop_mount() {
    dev=/dev/disk/by-uuid/@NTFS_UUID@
    n=0
    while [ ! -e "$dev" ] && [ $n -lt 40 ]; do sleep 0.5; n=$((n+1)); done
    modprobe loop
    modprobe ntfs3
    mkdir -p /ntfs
    mount -t ntfs3 -o rw,noatime "$dev" /ntfs || launch_interactive_shell
    losetup -P /dev/loop0 /ntfs/chilled.img || launch_interactive_shell
    n=0
    while [ ! -e /dev/loop0p1 ] && [ $n -lt 20 ]; do sleep 0.5; n=$((n+1)); done
    mount -t ext4 -o rw /dev/loop0p1 "$1" || launch_interactive_shell
    mkdir -p "$1/winc"
    mount --move /ntfs "$1/winc"
}
EOF
```

```
sudo sed -i "s/@NTFS_UUID@/$NTFS_UUID/" /mnt/cachy/etc/initcpio/hooks/ntfsloop
grep 'by-uuid' /mnt/cachy/etc/initcpio/hooks/ntfsloop
ls -l /mnt/cachy/etc/initcpio/install/ntfsloop /mnt/cachy/etc/initcpio/hooks/ntfsloop
```

The `grep` line must show the real UUID with no `@` signs.

```
sudo tee /mnt/cachy/etc/mkinitcpio.conf.d/90-ntfsloop.conf >/dev/null <<'EOF'
HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block ntfsloop filesystems)
EOF
```

```
sudo arch-chroot /mnt/cachy mkinitcpio -P
```

The build output must show `Running build hook: [ntfsloop]` for both kernels and end with "Initcpio image generation successful". Firmware warnings and the `consolefont` warning are expected.

```
sudo lsinitcpio /mnt/cachy/boot/initramfs-linux-cachyos.img | grep -E 'ntfsloop|ntfs3|loop\.ko|losetup'
df -h /mnt/cachy/boot
sudo mkdir -p /mnt/cachy/boot/EFI/BOOT
sudo cp -n /mnt/cachy/usr/lib/systemd/boot/efi/systemd-bootx64.efi /mnt/cachy/boot/EFI/BOOT/BOOTX64.EFI
ls -l /mnt/cachy/boot/EFI/BOOT
```

Unmount in this order, then power the VM off:

```
sudo umount -R /mnt/cachy
sudo qemu-nbd -d /dev/nbd0
sudo umount /mnt/win
sync
```

### F. Boot from the stick and check

Relaunch the VM without the `-cdrom` line. Select "Linux CachyOS" in the boot menu. Inside the booted system:

```
findmnt /
lsblk
ls /winc
cat /proc/cmdline
```

Pass: `/` is `loop0p1` and `chilled.img` is listed under `/winc`.

Then shut the guest down from the Xfce menu, and with the VM fully stopped, on the lab host in bash:

```
cd ~/chilled-lab
LOOP=$(sudo losetup -fP --show host.img); echo $LOOP
sudo ntfs-3g.probe --readwrite ${LOOP}p2; echo "exit code: $?"
sudo losetup -d $LOOP
```

Exit code 0 should mean the NTFS volume is clean (check `man ntfs-3g.probe` for other codes).

## Step 1: clean state for each run (changed)

The plan was to keep reflink copies of the lab disks (`host.clean.img`, `stick.clean.img`) and copy them back between runs. They were not made, because the lab host has very little free disk space.

Instead, each run starts by deleting the lab disks and recreating them from scratch (section A of the clean run above), plus a fresh `OVMF_VARS.fd`. That needs no extra space beyond the disks themselves, and it makes the starting state reproducible from commands rather than from a stored copy. Planned: turn section A into `scripts/lab-reset.sh`.

## Step 2: lab disks (done before this log)

- `host.img` (20 GiB, raw): GPT, 300 MiB EFI partition (FAT32, label HOSTESP), rest NTFS (label HOSTWIN).
- `stick.img` (4 GiB, raw): empty.
- Partitioned with `sgdisk -n1:0:+300M -t1:ef00 -n2:0:0 -t2:0700`, then `mkfs.fat -F32` and `mkntfs -f -L HOSTWIN`.
- Note: the NTFS volume was made by Linux, so it is not identical to one made by Windows. Windows-side steps need a Windows evaluation VM later.

## Step 3: boot the VM

The host disk is emulated as NVMe and the stick as a USB disk, to match the real laptop's device names and transport.

```
qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=$HOME/chilled-lab/OVMF_VARS.fd \
  -drive file=$HOME/chilled-lab/host.img,format=raw,if=none,id=host \
  -device nvme,drive=host,serial=hostdisk \
  -device qemu-xhci \
  -drive file=$HOME/chilled-lab/stick.img,format=raw,if=none,id=stick \
  -device usb-storage,drive=stick,removable=on \
  -cdrom $HOME/Downloads/<cachyos-iso-name>.iso \
  -nic user,model=virtio-net-pci -device virtio-vga -display gtk
```

Saved as `scripts/lab-boot.sh`. The NVMe kernel parameters used on the real laptop are not needed in the VM.

**Reported result:** VM booted the live ISO. No errors.

## Step 4: prepare the image and the stick (inside the live session)

Check the disks first. Expected: a 20G `nvme0n1` with `HOSTWIN` as `nvme0n1p2`, and a 4G `sda` with `usb` in the TRAN column.

```
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL
```

Mount the NTFS volume and create the image:

```
sudo mkdir -p /mnt/win
sudo mount -t ntfs3 -o rw,noatime /dev/nvme0n1p2 /mnt/win
sudo dd if=/dev/zero of=/mnt/win/chilled.img bs=1M count=12288 status=progress
```

This writes a fully allocated 12 GiB image. **Difference from the real flow:** on a real Windows host the image is created from Windows with `fsutil file createnew` and `fsutil file setvaliddata`, so Linux never has to extend it. The lab cannot do that, so it writes zeros instead.

Expose the image as a disk and give it a partition table:

```
sudo pacman -Sy --needed qemu-img
sudo modprobe nbd max_part=8
sudo qemu-nbd --format=raw --cache=writethrough --connect=/dev/nbd0 /mnt/win/chilled.img
sudo parted -s /dev/nbd0 mklabel gpt mkpart root ext4 1MiB 100%
sudo partprobe /dev/nbd0
lsblk /dev/nbd0
```

Prepare the stick (confirm `sda` is the 4G USB disk and `findmnt | grep sda` prints nothing first):

```
sudo parted -s /dev/sda mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
sudo partprobe /dev/sda
sudo mkfs.fat -F32 -n CHILLEDBOOT /dev/sda1
```

**Reported result:** all commands ran without errors.

## Step 5: run the installer

Closed and relaunched the installer so it rescanned, then opened the Storage device dropdown.

**Gate result: `/dev/nbd0` was listed.** The installer accepted the image as an installation target. This answers the "install method" open question for this installer version: the installer route through `qemu-nbd` works.

Settings used:

- Partitions: manual. `/dev/nbd0p1` mounted at `/`, ext4. `/dev/sda1` mounted at `/boot`, FAT32, esp flag. Nothing on `nvme0n1` touched.
- Bootloader: systemd-boot.
- Desktop: Xfce.
- "Restart now" unticked at the end.

**Observations:**

- Editing `/dev/nbd0p1` required switching it to "format". The partition is empty (no filesystem yet), so formatting is required. The partition's name/label was cleared when it was formatted.
  - Design note: the tool must not depend on the partition label. The boot hook mounts by device path (`/dev/loop0p1`), so this does not affect booting.
- Result: install completed without errors.

## Step 6: add the boot hook and rebuild the initramfs (done)

### 6.1 Mount and inspect (done)

```
sudo mkdir -p /mnt/cachy
sudo mount /dev/nbd0p1 /mnt/cachy
sudo mount /dev/sda1 /mnt/cachy/boot
ls /mnt/cachy/boot /mnt/cachy/boot/loader/entries
grep '^HOOKS' /mnt/cachy/etc/mkinitcpio.conf
ls /mnt/cachy/etc/mkinitcpio.conf.d
cat /mnt/cachy/etc/mkinitcpio.conf.d/10-chwd-qemu.conf
cat /mnt/cachy/boot/loader/entries/linux-cachyos.conf
```

Observed:

- A first `ls` failed only because the path was missing its leading `/`. Harmless.
- The stick's `/boot` holds two kernels (`vmlinuz-linux-cachyos` and `vmlinuz-linux-cachyos-lts`), a matching initramfs for each, `intel-ucode.img`, `loader`, `EFI`, and a directory named after a machine ID.
- Two loader entries exist: `linux-cachyos.conf` and `linux-cachyos-lts.conf`.
- The `linux-cachyos.conf` entry:
  - `options root=UUID=<image root partition> rw nowatchdog quiet splash`
  - `linux /vmlinuz-linux-cachyos`
  - `initrd /initramfs-linux-cachyos.img`
  - There is no separate microcode `initrd` line, because the `microcode` hook puts microcode inside the initramfs.
- `HOOKS` in `/etc/mkinitcpio.conf` is the systemd flavor: `base systemd autodetect microcode kms modconf block keyboard sd-vconsole plymouth filesystems fsck`.
- The drop-in `10-chwd-qemu.conf` was generated by chwd (CachyOS hardware detection) because the installer detected a VM. It only adds `MODULES+=(virtio virtio_blk virtio_pci virtio_net)` and does not set `HOOKS`. A real-hardware install will not have this file.

### 6.2 Read the lab NTFS volume's UUID (done)

```
NTFS_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p2); echo $NTFS_UUID
```

Result: `752A137150CCC9D4`.

### 6.3 Create the hook files (first attempt failed, second succeeded)

**First attempt (failed).** The commands were pasted as one block. No hook files were created: `ls -l` on both folders afterwards showed `total 0`. Only the `mkdir -p /mnt/cachy/etc/initcpio/{install,hooks}` and the `blkid` line ran.

Cause: the pasted block had leading spaces on every line, copied from an indented code block. A `<<'EOF'` heredoc only ends on a line that is exactly `EOF` with nothing before it. The indented `EOF` lines never matched, so the shell stayed at a `>` continuation prompt, and the command was cancelled with Ctrl+C.

**Second attempt (succeeded).** Each file was written with `sudo tee <file> >/dev/null <<'EOF'` from an unindented block, one block at a time. Results:

- `install/ntfsloop` (159 bytes) and `hooks/ntfsloop` (585 bytes) now exist.
- After `sed` replaced the placeholder, `grep 'by-uuid'` shows `dev=/dev/disk/by-uuid/752A137150CCC9D4`.
- The `sed` command was run twice by accident. The second run changed nothing, because the placeholder was already gone, so the step is safe to repeat.
- While a heredoc is being pasted, the terminal shows `>` at the start of each line. That is normal continuation-prompt behavior, not an error. The real failure signal is that the normal prompt never comes back after the `EOF` line.

Lessons for the tool:

- Never generate files by pasting heredocs into a terminal. Ship the hook files as real files in the repo and copy them, filling in values with a template (here `@NTFS_UUID@` replaced by `sed`).
- Verify every file exists and has the expected content right after writing it, and stop on a mismatch.
- Documentation code blocks must not be indented, or they cannot be copy-pasted safely.

### 6.4 Drop-in and rebuild (done)

```
sudo tee /mnt/cachy/etc/mkinitcpio.conf.d/90-ntfsloop.conf >/dev/null <<'EOF'
HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block ntfsloop filesystems)
EOF
sudo arch-chroot /mnt/cachy mkinitcpio -P
sudo lsinitcpio -a /mnt/cachy/boot/initramfs-linux-cachyos.img | head -20
```

Instead of editing `HOOKS` in `/etc/mkinitcpio.conf`, the replacement list lives in its own drop-in. Removing `90-ntfsloop.conf` undoes the change.

Observed:

- `mkinitcpio -P` rebuilt both presets: `linux-cachyos-lts` (kernel 6.18.60-1-cachyos-lts) and `linux-cachyos` (kernel 7.3.1-1-cachyos). Both ended with "Initcpio image generation successful".
- For both builds the log says `Using drop-in configuration file: '10-chwd-qemu.conf'` and `'90-ntfsloop.conf'`. With mkinitcpio 42.2, the drop-in is applied as intended.
- Build hooks ran in this order: base, udev, microcode, modconf, kms, keyboard, keymap, consolefont, block, **ntfsloop**, filesystems.
- Warnings (treated as harmless): "Possibly missing firmware" for modules `ast`, `xhci_pci_renesas`, `bfa`, `wd719x`, `qed`, `qla2xxx`, `qla1280` and `aic94xx`, and `consolefont: no font found in configuration`. These modules are pulled in because `autodetect` is not used, and the VM has no such hardware.
- `lsinitcpio -a` on `initramfs-linux-cachyos.img`: made with mkinitcpio 42.2, 12.83 MiB compressed with zstd, 38.73 MiB uncompressed, 1056 modules, and an early CPIO of 198.81 MiB. The output was cut off by `head -20` before the "Hooks used" section, so the hook list itself was not displayed. The build log is the evidence that `ntfsloop` was included.
- The early CPIO is large. The cause is not verified; removing `autodetect` is a likely factor. Each initramfs on the stick is therefore about 210 MiB, and there are two kernels.

**Result:** both initramfs images rebuilt with the `ntfsloop` hook. Contents of the image still to be spot-checked (see 6.5).

### 6.5 Image spot-check, boot-stick fallback entry and unmount (done, as reported)

Commands given for this step:

```
sudo lsinitcpio /mnt/cachy/boot/initramfs-linux-cachyos.img | grep -E 'ntfsloop|ntfs3|loop\.ko|losetup'
df -h /mnt/cachy/boot
sudo mkdir -p /mnt/cachy/boot/EFI/BOOT
sudo cp -n /mnt/cachy/usr/lib/systemd/boot/efi/systemd-bootx64.efi /mnt/cachy/boot/EFI/BOOT/BOOTX64.EFI
ls -l /mnt/cachy/boot/EFI/BOOT
sudo umount -R /mnt/cachy
sudo qemu-nbd -d /dev/nbd0
sudo umount /mnt/win
sync
```

Reported: the VM was then powered off and relaunched without the `-cdrom` line (using `~/chilled-lab/scripts/lab-boot.sh`). The output of the individual commands above was not captured, so the spot-check results and the free space on the stick are not recorded. Fill in if available.

## Step 7: boot the VM from the stick only (done)

Relaunched the VM without the `-cdrom` line.

Observed (reported by the author, with a screenshot of the desktop):

- The firmware went to the systemd-boot menu, shown as a mostly black screen with the entries. Selecting "Linux CachyOS" booted the system.
- The system reached the Xfce desktop, with the CachyOS Hello welcome window open, without dropping to the `[rootfs ~]#` rescue shell.

Verification, reported by the author as correct (raw output not captured):

```
findmnt /
lsblk
ls /winc
cat /proc/cmdline
```

Reported result: `/` is the loop-mounted image partition and the NTFS volume with `chilled.img` is mounted at `/winc`.

Clean-shutdown check, reported as correct (the exact exit code was not captured, so this is to be re-confirmed in the clean run):

```
LOOP=$(sudo losetup -fP --show host.img); echo $LOOP
sudo ntfs-3g.probe --readwrite ${LOOP}p2; echo "exit code: $?"
sudo losetup -d $LOOP
```

Still open:

- Whether the firmware booted via the NVRAM entry the installer wrote into `OVMF_VARS.fd`, or via the fallback `EFI/BOOT/BOOTX64.EFI` on the stick. Only the fallback matters on a real machine, which will not have that NVRAM entry. The clean run starts from a fresh `OVMF_VARS.fd` and answers this.

**Result:** passed, as reported.

## Step 8: repeat from clean (next)

Follow only the "Clean run" section above, starting from section A (fresh disks and fresh firmware variables). Record the time it takes, every command that had to be changed, and every point where the doc was not enough.

Pass: the VM boots to the desktop, `/` is `loop0p1`, `chilled.img` is under `/winc`, and the clean-shutdown check returns 0. If it passes twice without improvising, tag v0.1.

## Open issues and notes

- Image creation differs between the lab (`dd`) and the real flow (`fsutil` on Windows).
- The lab NTFS volume was created by Linux, not Windows.
- A kernel or bootloader update on a real install can regenerate the loader entry and drop manual edits. Kernel parameters should be set in a persistent config (for example `/etc/kernel/cmdline` or `/etc/sdboot-manage.conf`, depending on the distro tooling), not only in the entry file. Not yet tested.
- The CachyOS installer adds a hardware-specific mkinitcpio drop-in (`10-chwd-qemu.conf`) in a VM. Real hardware gets different (or no) drop-ins, so the tool must not assume the contents of `/etc/mkinitcpio.conf.d/`.
- The installer creates two kernels (`linux-cachyos` and `linux-cachyos-lts`) and a loader entry for each. Both initramfs images must be rebuilt, and any kernel parameter change has to reach both entries.
- The `root=UUID=...` in the loader entry points at the image's root partition. The boot hook ignores it, but it is still present.
- Without `autodetect`, the initramfs images are large (about 210 MiB each, two kernels). The stick needs room for this, and a small EFI partition would be tight. Check free space on the stick as a preflight item.
- `consolefont` warns that no font is configured, and `keymap` is only needed for encrypted roots. Both could probably be dropped from the hook list. Not tested.
