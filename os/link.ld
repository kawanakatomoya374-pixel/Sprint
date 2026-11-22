ENTRY(_start)
SECTIONS
{
    . = 1M;   /* BIOS / GRUB; the UEFI build uses a copy of this script linked at 16 MiB (firmware owns memory near 8 MiB) */
    .multiboot2 : { KEEP(*(.multiboot2)) }
    .text : ALIGN(4096) { *(.text .text.*) }
    .rodata : ALIGN(4096) { *(.rodata .rodata.*) }
    .data : ALIGN(4096) { *(.data .data.*) }
    .bss : ALIGN(4096) { *(COMMON) *(.bss .bss.*) }
    _end = .;
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
