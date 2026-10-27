ENTRY(_start)
SECTIONS
{
    . = 1M;
    .multiboot2 : { KEEP(*(.multiboot2)) }
    .text : ALIGN(4096) { *(.text .text.*) }
    .rodata : ALIGN(4096) { *(.rodata .rodata.*) }
    .data : ALIGN(4096) { *(.data .data.*) }
    .bss : ALIGN(4096) { *(COMMON) *(.bss .bss.*) }
    _end = .;
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
