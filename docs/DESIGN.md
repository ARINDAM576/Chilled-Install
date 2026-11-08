# Chilled-Install — Design (v0.1, Saturday, November 7th, 2026)

## Problem
Running Linux on a PC without repartitioning requires a lot of manual steps that are easy to get wrong.

## Goals (version 1)
- Allow creating and installing an Arch-based system, on a UEFI/GPT machine, with the image on a Windows NTFS volume
- Allow booting into the image using an external USB drive, which has the bootloader, kernel, initramfs.
- The only writes are one image file on the NTFS partition and the USB stick, which is erased. No other partition or device is written.
- MUST stop if any preflight check fails (Dirty NTFS, BitLocker, too little space, etc).

## Non-goals
- BIOS/MBR, Secure Boot
- Other distros than Arch-Linux

## Future work
- Enable users to have a portable OS, by easy recovery of root and easy syncing or carry-over of user environments on any machine.
- Provide a way to relink the image and external USB anytime and anywhere through a recovery environment, enabling to boot the install on any machine.

## How it works
The USB stick holds a small FAT32 EFI partition with the bootloader (systemd-boot), the kernel and an initramfs that contains a custom hook. The host disk holds one raw image file on the NTFS volume (working name `chilled.img`). The image contains a GPT with a single ext4 partition, which becomes the root filesystem.

The image is created from Windows with its full size allocated up front, so Linux never has to extend it or change NTFS metadata while running.

```
UEFI firmware
  -> systemd-boot (USB stick, FAT32 EFI partition)
  -> kernel + initramfs (USB stick)
  -> hook: mount NTFS volume (host disk) -> attach image as a loop device -> mount its ext4 partition as /
  -> normal Linux boot; the NTFS volume stays mounted inside the new root
```

The hook has to match the distro's initramfs flavor (busybox-based or systemd-based). The host's EFI partition and Windows boot configuration are never modified.

## Safety rules
- MUST show the model, size, transport and mount state of every disk it could use, and require the user to pick the USB stick explicitly. MUST NOT choose a device automatically.
- MUST refuse any target that is mounted, holds the running system's root, or is the same disk as the selected NTFS volume.
- MUST require the user to type the device name (for example `/dev/sda`) before erasing the stick.
- MUST NOT write to anything except the image file on the NTFS volume and the USB stick. Test: checksums of all other partitions are identical before and after a run.
- MUST run every preflight check before the first write and stop on any failure: NTFS volume clean (not dirty), not BitLocker-encrypted, Windows not hibernated and Fast Startup off, enough free space (image size plus a reserve for Windows), UEFI and GPT detected, volume mountable read-write, no SMART critical warning on the host drive.
- MUST NOT run any repair action on the user's NTFS volume. If it is dirty, the tool stops and tells the user to fix it from Windows.
- MUST NOT modify the host's EFI partition or Windows boot configuration.
- MUST offer a dry run that prints every command it would run and changes nothing.
- MUST unmount, detach and flush in the correct order on exit, including after an error or interrupt.
- MUST log every command and its result to a file the user can attach to a bug report.

## Supported and unsupported environments
Nothing is listed as supported until it has passed the testing plan below.

**Target (to be verified):**
- x86_64, UEFI firmware, GPT disks
- Windows 10/11 host, NTFS volume, BitLocker off, Fast Startup and hibernation off
- Arch and Arch-based distributions (Arch, CachyOS)
- A kernel with the `ntfs3` driver

**Known to fail or out of scope:**
- BitLocker or Device Encryption on the NTFS volume
- Secure Boot enabled (unsigned bootloader)
- BIOS/MBR
- A dirty NTFS volume (hibernation, Fast Startup, unclean shutdown)
- A host drive with unreadable regions that Linux cannot read
- Non-Arch distributions

## Risks and known limits
- **Wrong device erased.** The biggest risk. Reduced by the device-selection and typed-confirmation rules.
- **Power loss or crash while running.** ext4 inside an NTFS file is journaled at both levels, but data loss is still possible. Mitigation: preflight checks, clean shutdowns, and a documented recommendation to back up first.
- **NTFS left dirty by a hard power-off.** Windows will run a disk check on its next boot. Mitigation: documentation.
- **Failing host drive.** The tool cannot repair hardware. It only checks SMART and stops on a critical warning.
- **Windows changing the image.** Moving, renaming, defragmenting, deleting or cloud-syncing the file breaks the install. Mitigation: documentation.
- **Windows re-enabling Fast Startup** after an update makes the read-write mount fail. The hook should fail with a clear message.
- **TRIM does not pass through** the image. Accepted: slightly less efficient wear leveling.
- **Performance overhead** from layered I/O (ext4, loop, NTFS, SSD).
- **The image permanently uses host free space** until the file is deleted.

## Testing plan
Testing runs in stages. Nothing moves to the next stage until the current one passes repeatedly with zero unexpected writes.

### Stage 1: lab (virtual machines)
All destructive and repetitive testing happens here. A failure costs nothing, many full install cycles do not wear a real drive, and a VM separates bugs in the tool from faults in hardware. CI can only run at this stage.

- **Lab:** QEMU/KVM with OVMF (UEFI). One virtual host disk (GPT, EFI partition, NTFS volume) and one virtual USB stick. A Windows evaluation VM is used for the Windows-side steps.
- **Preflight tests:** each failure case (dirty NTFS, BitLocker volume, too little space, mounted stick, stick on the same disk as the NTFS volume) must be blocked before any write.
- **Install test:** the VM boots from the stick to a login prompt, root is the image, and the NTFS volume is mounted inside it.
- **No-collateral-writes test:** checksums of every other partition, and of the NTFS volume's other contents, are identical before and after.
- **Error injection:** kill the tool or power off the VM at each stage. Nothing may be left mounted, and a re-run must succeed.
- **Shutdown test:** repeated boot and clean-shutdown cycles must not leave the NTFS volume dirty.
- **Dry run test:** it prints the command list and changes no disk.
- **Tooling:** `shellcheck`, `bats`, and a CI job that boots the VM headless and checks for a login prompt.

### Stage 2: real hardware (the author's own machine)
Real hardware finds what a VM cannot: real firmware and USB boot behavior, NVMe power-state problems, `ntfs3` on a real volume with real bad clusters, BitLocker and Fast Startup states, and real performance. A tool that only passes in QEMU is not proven.

Only the non-destructive tests run here: preflight, dry run, install, boot, clean-shutdown cycles, and the no-collateral-writes checksums. No error injection and no cutting power mid-run.

Before every hardware run:
- Backups of anything important on the machine are current.
- The dry run output has been read.
- The environment is recorded: firmware version, kernel, tool version, drive model.
- Only one thing changes between runs.

A machine whose drive is known to be damaged is a hard-mode environment. A pass there is a strong sign. A failure there is not proof that the tool is wrong, so re-check it in the lab and on a healthy drive before drawing conclusions.

### Stage 3: other people's machines
Only after Stage 2 has passed, with the owner's consent and a current backup, and with the tester having read the dry run.

### Pass criteria
Every test above passes with zero unexpected writes.

## Milestones
- **v0.1:** this design doc, plus the manual flow documented end to end and reproduced in the VM lab.
- **v0.2:** command-line scripts for preflight, image creation, install, boot hook and clean unmount, with a dry run. First non-destructive Stage 2 run on the author's own machine.
- **v0.3:** complete safety layer (device picker, typed confirmation, logs), error-injection tests, and the second initramfs flavor.
- **v0.4:** grow-the-image support and uninstall.
- **v0.5:** TUI or GUI front end.
- **v1.0:** tested on real hardware by several people, with docs and a known-issues list.

## Open questions
- **Install method:** use the distro's own installer through `qemu-nbd`, or `pacstrap`? Whether the installer lists the device depends on its version. Support both?
- **Initramfs flavor:** busybox-based hooks or systemd-based, and which is the default for v1?
- **Finding the image:** hard-coded NTFS UUID, or scan for the file name? This also decides how much of the portability work in Future work is possible.
- **Windows-side step:** a PowerShell script, or everything from Linux? Writing NTFS metadata from Linux is the riskier option.
- **Free-space reserve:** how much should the tool always leave for Windows?
- **SMART policy:** which readings stop the tool and which only warn?
- **Image name and location** on the volume.
- **Host scope:** Windows hosts only, or any NTFS volume?
