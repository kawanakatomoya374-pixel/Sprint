/* The initial RAM disk: the user-space program image, linked into the kernel. */
    .section .rodata
    .align 4096
    .global initrd_userland_start
    .global initrd_userland_end
initrd_userland_start:
    .incbin "userland.elf"
initrd_userland_end:
    .section .note.GNU-stack, "", @progbits
