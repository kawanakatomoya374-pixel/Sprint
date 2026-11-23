# Sprint OS UEFI boot: a GPT disk image with an EFI System Partition, written entirely in Sprint.
#
#   \EFI\BOOT\BOOTX64.EFI   the loader: an x86-64 EFI application assembled with `asm` and wrapped by uefi_pe.sp
#   \SPRINTOS.BIN           the kernel's PT_LOAD segments, concatenated (the loader carries the table: file offset, address, sizes)
#
# The loader (UEFI, 64-bit, Microsoft ABI) picks a 1024x768 GOP mode, finds the ACPI RSDP in the configuration tables, reads
# SPRINTOS.BIN from the file system it was started from, builds a Multiboot2 information structure (command line, framebuffer, RSDP,
# memory map), checks that the kernel's address ranges are free memory, calls ExitBootServices and finally runs a small trampoline in low
# memory: back to 32-bit protected mode with paging and long mode switched off, copy the kernel segments into place, then the kernel's
# Multiboot2 entry (eax = 0x36d76289, ebx = the information structure) - the convention the GRUB and BIOS paths use, so the kernel
# is unchanged. The code is in uefi_loader.sp (shared with the hybrid image, hybridboot.sp).
#
# usage: sprint run --allow-read=DIR --allow-write=DIR os/boot/uefiboot.sp KERNEL32.ELF OUT.IMG "kernel command line" KERNEL64.ELF
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
let elf64 = fs.read_bytes(sys.args[3])      # the 64-bit kernel.elf (relocations)
let u = uefi_loader.build(elf, info, cmdline, elf64)
let d = diskimg.Disk(81920)
let efi_dir = d.mkdir(d.root, "EFI")
let boot_dir = d.mkdir(efi_dir, "BOOT")
d.write_file(boot_dir, "BOOTX64.EFI", u.efi)
d.write_file(d.root, "SPRINTOS.BIN", u.kbin)
let img = d.finish()
fs.write_bytes(out_path, img)
print("sprint uefi loader: BOOTX64.EFI " .. to_string(len(u.efi)) .. " bytes, " .. to_string(u.nsegs) .. " segments (" .. to_string(u.kbin_size) .. " bytes), disk " .. to_string(len(img)) .. " bytes")
