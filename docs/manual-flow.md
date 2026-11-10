# Manual flow (lab log)

Working log of the manual install flow, reproduced step by step in a VM lab. This is the source for the v0.1 milestone and for the automation scripts in v0.2.

**Status:** Complete (Milestone v0.1 verified). All steps 1 to 8 executed and verified cleanly.

> Everything below is a record of what was run and what was observed. A step is only marked as verified when it was actually run and the result was checked. Commands are not guaranteed to work on other hardware, distros, or versions.

---

## Environment

| Item | Value |
|---|---|
| Host OS (lab machine) | CachyOS, Hyprland |
| Host shell | bash (scripts must use a `#!/usr/bin/env bash` shebang) |
| Host RAM | 8 GB (VM gets 4 GB) |
| QEMU version | 11.1.3 |
| OVMF / edk2 version | 202608-1 |
| Guest ISO | CachyOS desktop ISO, version/date: 260809 |

---

## Host tool dependencies found so far

These were missing on a normal desktop install and caused failures. The tool's preflight should check for each command and name the package to install.

| Needed command | Package (Arch) | Used for |
|---|---|---|
| `sgdisk` | `gptfdisk` | partitioning the lab disks |
| `mkfs.ntfs` / `mkntfs` | `ntfsprogs` (pulled in as optional dependency of `ntfs-3g`) | formatting the lab NTFS volume |
| `qemu-system-x86_64`, `qemu-img` | `qemu-full` | running the lab VM |
| OVMF firmware files | `edk2-ovmf` | UEFI support in the VM |
| `qemu-nbd` | `qemu-img` (inside the live session) | exposing the image file as a block disk |

**Lesson:** Pasting a block of commands keeps executing after one fails (e.g., `sgdisk` failed, then `mkfs.fat` attempted to run against partitions that did not exist). All scripts must use `set -euo pipefail`.

---

## Clean run: the commands that worked, in order

Consolidated sequence for repeating the flow from scratch (Step 8). Run the lab-host commands in bash, not fish. Every code block here is unindented so it can be pasted safely.

Prerequisites on the lab host: `gptfdisk`, `ntfs-3g`, `ntfsprogs`, `dosfstools`, `qemu-full`, `edk2-ovmf`, and the CachyOS desktop ISO.

### A. Lab host: fresh disks and firmware variables

This resets the virtual disks cleanly. Automated via `scripts/lab-reset.sh`:

```bash
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

Expected: `loop0p1` (~300M, `vfat`, label HOSTESP) and `loop0p2` (~19.7G, `ntfs`, label HOSTWIN).

### B. Boot the live ISO in the VM

Run `scripts/lab-boot.sh` with the `-cdrom` line active pointing to the CachyOS desktop ISO.

### C. In the VM's live session: image, nbd, partition table, stick

Open a terminal inside the live session:

```bash
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

Before preparing the stick, confirm `sda` is the 4G USB disk and that `findmnt | grep sda` prints nothing:

```bash
sudo parted -s /dev/sda mklabel gpt mkpart ESP fat32 1MiB 100% set 1 esp on
sudo partprobe /dev/sda
sudo mkfs.fat -F32 -n CHILLEDBOOT /dev/sda1
```

### D. The installer

Close and relaunch the Calamares installer so it rescans block devices. `/dev/nbd0` must appear in the storage target list.

- **Partitions (Manual):**
  - Select `/dev/nbd0p1` -> Edit -> Mount Point: `/`, File System: `ext4`, Check `Format`.
  - Select `/dev/sda1` -> Edit -> Mount Point: `/boot`, File System: `fat32`, Check `Format`, Flag: `boot`/`esp`.
  - **Do not touch `/dev/nvme0n1`.**
- **Bootloader:** Select `systemd-boot`.
- **Desktop:** Minimal or Xfce.
- **Finish:** Untick "Restart now" on the final screen before clicking Done.

### E. After the install: hook, drop-in, rebuild, fallback, unmount

Mount the installed target and the boot stick inside the live session:

```bash
sudo mkdir -p /mnt/cachy
sudo mount /dev/nbd0p1 /mnt/cachy
sudo mount /dev/sda1 /mnt/cachy/boot
NTFS_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p2); echo $NTFS_UUID
sudo mkdir -p /mnt/cachy/etc/initcpio/{install,hooks} /mnt/cachy/etc/mkinitcpio.conf.d
```

Write the `ntfsloop` install hook:

```bash
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

Write the `ntfsloop` runtime mount hook:

```bash
sudo tee /mnt/cachy/etc/initcpio/hooks/ntfsloop >/dev/null <<EOF
#!/usr/bin/ash
run_hook() {
    mount_handler=ntfsloop_mount
}
ntfsloop_mount() {
    dev=/dev/disk/by-uuid/$NTFS_UUID
    n=0
    while [ ! -e "\$dev" ] && [ \$n -lt 40 ]; do sleep 0.5; n=\$((n+1)); done
    modprobe loop
    modprobe ntfs3
    mkdir -p /ntfs
    mount -t ntfs3 -o rw,noatime "\$dev" /ntfs || launch_interactive_shell
    losetup -P /dev/loop0 /ntfs/chilled.img || launch_interactive_shell
    n=0
    while [ ! -e /dev/loop0p1 ] && [ \$n -lt 20 ]; do sleep 0.5; n=\$((n+1)); done
    mount -t ext4 -o rw /dev/loop0p1 "\$1" || launch_interactive_shell
    mkdir -p "\$1/winc"
    mount --move /ntfs "\$1/winc"
}
EOF
```

Configure the mkinitcpio drop-in to register `ntfsloop` without modifying vendor defaults:

```bash
sudo tee /mnt/cachy/etc/mkinitcpio.conf.d/90-ntfsloop.conf >/dev/null <<'EOF'
HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block ntfsloop filesystems)
EOF
```

Rebuild initramfs for all kernels and configure fallback UEFI binary:

```bash
sudo arch-chroot /mnt/cachy mkinitcpio -P
sudo mkdir -p /mnt/cachy/boot/EFI/BOOT
sudo cp -n /mnt/cachy/usr/lib/systemd/boot/efi/systemd-bootx64.efi /mnt/cachy/boot/EFI/BOOT/BOOTX64.EFI
```

Clean unmount and flush all writes:

```bash
sudo umount -R /mnt/cachy
sudo qemu-nbd -d /dev/nbd0
sudo umount /mnt/win
sync
sudo poweroff
```

### F. Boot from the stick and verify

Comment out `-cdrom` in `scripts/lab-boot.sh` and relaunch the VM.

Select "Linux CachyOS" in the systemd-boot menu. Inside the booted desktop:

```bash
findmnt /
lsblk
ls -lh /winc
cat /proc/cmdline
```

**Pass criteria:** `/` is `/dev/loop0p1`, and `chilled.img` (12G) is present under `/winc`.

Shut down from the desktop menu. Once the VM has completely exited, test filesystem cleanliness on the host:

```bash
cd ~/chilled-lab
LOOP=$(sudo losetup -fP --show host.img); echo $LOOP
sudo ntfs-3g.probe --readwrite ${LOOP}p2; echo "exit code: $?"
sudo losetup -d $LOOP
```

**Verification result:** Exit code `0` confirmed. The host NTFS volume remained clean without dirty flags.

---

## Detailed step-by-step logs

### Step 1: Clean state for each run (Done)
Automated via `scripts/lab-reset.sh`. Rebuilding `host.img`, `stick.img`, and resetting `OVMF_VARS.fd` provides an exact, clean baseline for each cycle without requiring storage-heavy reflink copies.

### Step 2: Lab disks (Done)
- `host.img` (20 GiB, raw): GPT, 300 MiB EFI partition (`vfat`, label HOSTESP), remainder NTFS (label HOSTWIN).
- `stick.img` (4 GiB, raw): empty GPT table.
- Initialized with `sgdisk`, `mkfs.fat`, and `mkntfs`.

### Step 3: Boot the VM (Done)
- Host disk emulated as NVMe and stick emulated as USB storage to reproduce real hardware behavior.
- Handled through `scripts/lab-boot.sh` with bash array syntax to avoid multi-line backslash escape errors.

### Step 4: Prepare the image and the stick (Done)
- Mounted `/dev/nvme0n1p2` to `/mnt/win`.
- Allocated 12 GiB zeroed file `chilled.img` with `dd`.
- Attached to `/dev/nbd0` via `qemu-nbd`.
- Partitioned `nbd0p1` and formatted `/dev/sda1` as `CHILLEDBOOT` ESP.

### Step 5: Run the installer (Done)
- Calamares listed `/dev/nbd0` in the device dropdown.
- Configured manual mount points: `/dev/nbd0p1` on `/`, `/dev/sda1` on `/boot`.
- System installed cleanly without touching `/dev/nvme0n1`.

### Step 6: Add the boot hook and rebuild initramfs (Done)
- Created `/etc/initcpio/install/ntfsloop` and `/etc/initcpio/hooks/ntfsloop`.
- Populated `@NTFS_UUID@` with the actual volume UUID.
- Placed hook list in `/etc/mkinitcpio.conf.d/90-ntfsloop.conf` between `block` and `filesystems`.
- Rebuilt both kernels with `mkinitcpio -P`. Verified `Running build hook: [ntfsloop]`.
- Created fallback EFI binary at `/boot/EFI/BOOT/BOOTX64.EFI`.
- Unmounted cleanly in sequence: `/mnt/cachy` -> `qemu-nbd -d` -> `/mnt/win` -> `sync`.

### Step 7: Boot the VM from the stick only (Done & Verified)
- Relaunched QEMU without `-cdrom`.
- Firmware picked up systemd-boot from `stick.img`.
- Boot hook mounted NTFS volume to `/ntfs`, attached loop device, pivoted root to `/dev/loop0p1`, and moved NTFS mount to `/winc`.
- Successfully reached the desktop environment.

### Step 8: Repeat from clean (Done & Verified)
- Executed full sequence from scratch using `scripts/lab-reset.sh`.
- Recreated image container, completed Calamares installation, injected hook, and verified cold boot.
- Verified root on `/dev/loop0p1`.
- Verified host NTFS cleanliness: `ntfs-3g.probe --readwrite` returned exit code `0`.
- **Milestone v0.1 officially complete.**

---

## Open issues and notes for v0.2

- **Automation:** Wrap manual steps into distinct scripts: `preflight.sh`, `setup-nbd.sh`, and `post-install.sh`.
- **Dynamic discovery:** Replace the static UUID injection with an automatic search loop that detects `chilled.img` across all available NTFS partitions.
- **Drop-in resilience:** CachyOS adds `10-chwd-qemu.conf` in virtual machines; `90-ntfsloop.conf` cleanly overrides `HOOKS` without package file conflicts.
- **Direct I/O:** Benchmark `losetup --direct-io=on` during boot to minimize double-caching overhead.
