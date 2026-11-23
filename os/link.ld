ENTRY(_start)
SECTIONS
{
    . = 1M;   /* the link address; a UEFI loader relocates the kernel (kernel.elf keeps its relocations) */
    __image_start = .;
    .multiboot2 : { KEEP(*(.multiboot2)) }
    .text : ALIGN(4096) { *(.text .text.*) }
    .rodata : ALIGN(4096) { *(.rodata .rodata.*) }
    .data : ALIGN(4096) { *(.data .data.*) }
    .bss : ALIGN(4096) { *(COMMON) *(.bss .bss.*) }
    _end = .;
    __tls_size = SIZEOF(.tbss);
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
