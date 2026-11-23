# Sprint OS hybrid image: ONE disk that boots under BIOS and under UEFI, written entirely in Sprint.
#
#   LBA 0         protective MBR whose boot code is the BIOS stage 1 (bios_loader.sp)      <- BIOS: runs this
#   LBA 1..33     GPT header and partition entries
#   partition 1   GPT "BIOS boot" partition: BIOS stage 2 and the kernel segments            <- BIOS: stage 1 reads it
#   partition 2   EFI System Partition (FAT32): \EFI\BOOT\BOOTX64.EFI and \SPRINTOS.BIN      <- UEFI: boots this (diskimg.sp, uefi_loader.sp)
#
# Both loaders enter the same kernel through its Multiboot2 entry: the BIOS loader copies it to its link address (1 MiB), the UEFI loader
# relocates it into a free block the firmware chose (the table comes from the 64-bit kernel.elf, linked with -Wl,-q).
#
# usage: sprint run --allow-read=DIR --allow-write=DIR os/boot/hybridboot.sp KERNEL32.ELF OUT.IMG "command line or menu spec" KERNEL64.ELF [KEY.pem CERT.pem]
import bios_loader
import authenticode
import diskimg
import elf32
import fs
import sys
import uefi_loader

let kernel_path = sys.args[0]
let out_path = sys.args[1]
let cmdline = sys.args[2] if len(sys.args) > 2 else "init=boot"
let elf = fs.read_bytes(kernel_path)
let info = elf32.parse(elf, kernel_path)

const BIOS_START = 2048          # the BIOS boot partition begins at 1 MiB
let b = bios_loader.build(elf, info, cmdline, BIOS_START)
let elf64 = fs.read_bytes(sys.args[3])      # the 64-bit kernel.elf (relocations)
let u = uefi_loader.build(elf, info, cmdline, elf64)
let efi = u.efi
if len(sys.args) > 5:       # KEY.pem CERT.pem: sign the loader for Secure Boot (authenticode.sp)
    efi = authenticode.sign(u.efi, fs.read_file(sys.args[4]), fs.read_file(sys.args[5]))
# the ESP follows, 1 MiB aligned
let esp_start = (BIOS_START + b.sectors + 2047) // 2048 * 2048
let d = diskimg.Disk(81920, esp_start)
let efi_dir = d.mkdir(d.root, "EFI")
let boot_dir = d.mkdir(efi_dir, "BOOT")
d.write_file(boot_dir, "BOOTX64.EFI", efi)
d.write_file(d.root, "SPRINTOS.BIN", u.kbin)
let img = d.finish({mbr: b.stage1, blob: b.blob, start: BIOS_START})
fs.write_bytes(out_path, img)
print("sprint hybrid image: BIOS " .. to_string(b.sectors) .. " sectors at LBA " .. to_string(BIOS_START) .. ", ESP at LBA " .. to_string(esp_start) ..
      ", " .. to_string(len(img)) .. " bytes")
