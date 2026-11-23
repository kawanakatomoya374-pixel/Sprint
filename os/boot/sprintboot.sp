# Sprint OS bootloader, written and assembled entirely in Sprint (no GRUB, no external assembler).
#
#   stage 1  MBR (512 bytes): reads stage 2 with INT 13h extensions
#   stage 2  real mode: A20, VBE 1024x768x32 linear framebuffer, ACPI RSDP search, E820 memory map, a Multiboot2 info structure,
#            then the kernel's PT_LOAD segments are read from disk into memory above 1 MiB through a bounce buffer ("unreal" mode
#            gives ES a flat 4 GiB limit for the copy), and finally 32-bit protected mode -> the kernel's Multiboot2 entry point
#            (eax = 0x36d76289, ebx = the info structure), exactly what GRUB provides.
#
# The kernel ELF is parsed here, at image-build time: the image holds each segment on its own sector boundary and stage 2 carries a
# small load table (lba, destination, file size, memory size), so the 16-bit loader never has to understand ELF.
# The code lives in bios_loader.sp (shared with the hybrid image, hybridboot.sp).
#
# usage: sprint run --allow-read=DIR --allow-write=DIR os/boot/sprintboot.sp KERNEL32.ELF OUT.IMG "command line or menu spec (see boot_menu.sp)"
import bios_loader
import elf32
import fs
import sys
import typed

let kernel_path = sys.args[0]
let out_path = sys.args[1]
let cmdline = sys.args[2] if len(sys.args) > 2 else "init=boot"
let elf = fs.read_bytes(kernel_path)
let info = elf32.parse(elf, kernel_path)
let b = bios_loader.build(elf, info, cmdline, 1)
let img = typed.u8(512 + len(b.blob))
for i in range(len(b.stage1)):
    img[i] = b.stage1[i]
img[510] = 0x55
img[511] = 0xaa
for i in range(len(b.blob)):
    img[512 + i] = b.blob[i]
fs.write_bytes(out_path, img)
print("sprint bootloader: stage 2 " .. to_string(b.stage2_bytes) .. " bytes, " .. to_string(len(info.segs)) .. " segments, entry 0x" .. to_string(info.entry) .. ", image " .. to_string(len(img)) .. " bytes")
