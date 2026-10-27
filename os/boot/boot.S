/* Sprint OS boot: Multiboot2 entry (32-bit), switch to long mode, enable SSE, call kmain().
 * GRUB leaves us in 32-bit protected mode with paging off; eax = 0x36d76289, ebx = boot info. */
#define MB2_MAGIC 0xE85250D6
#define MB2_ARCH  0
#define MB2_LEN   (mb2_end - mb2_start)

    .section .multiboot2, "a"
    .align 8
mb2_start:
    .long MB2_MAGIC
    .long MB2_ARCH
    .long MB2_LEN
    .long -(MB2_MAGIC + MB2_ARCH + MB2_LEN)
    /* ask for a 1024x768x32 linear framebuffer */
    .align 8
    .short 5
    .short 0
    .long 20
    .long 1024
    .long 768
    .long 32
    .align 8
    .short 0
    .short 0
    .long 8
mb2_end:

    .section .bss
    .align 4096
    .global pml4
pml4:   .skip 4096
pdpt:   .skip 4096
pd0:    .skip 4096
pd1:    .skip 4096
pd2:    .skip 4096
pd3:    .skip 4096
    .align 16
    .global boot_stack_bottom
boot_stack_bottom:
    .skip 8 * 1024 * 1024
    .global boot_stack_top
boot_stack_top:
    .global mbi_ptr
mbi_ptr: .skip 8

    .section .rodata
    .align 16
gdt64:
    .quad 0
    .quad 0x00AF9A000000FFFF   /* 0x08: 64-bit code, ring 0 */
    .quad 0x00CF92000000FFFF   /* 0x10: data, ring 0 */
gdt64_end:
gdt64_ptr:
    .word gdt64_end - gdt64 - 1
    .long gdt64

    .section .text
    .code32
    .global _start
_start:
    cli
    movl %ebx, %esi                 /* keep the boot info pointer */
    /* page tables: identity map the first 4 GiB with 2 MiB pages */
    movl $pdpt, %eax
    orl $3, %eax
    movl %eax, pml4
    movl $0, %ecx
1:  movl %ecx, %eax
    shll $12, %eax
    addl $pd0, %eax
    orl $3, %eax
    movl %eax, pdpt(, %ecx, 8)
    incl %ecx
    cmpl $4, %ecx
    jne 1b
    movl $0, %ecx                   /* 2048 entries of 2 MiB over pd0..pd3 */
2:  movl %ecx, %eax
    shll $21, %eax
    orl $0x83, %eax                 /* present | writable | huge */
    movl %eax, pd0(, %ecx, 8)
    movl %ecx, %eax
    shrl $11, %eax                  /* bits 32..: ecx * 2MiB >> 32 */
    movl %eax, pd0 + 4(, %ecx, 8)
    incl %ecx
    cmpl $2048, %ecx
    jne 2b
    movl $pml4, %eax
    movl %eax, %cr3
    movl %cr4, %eax
    orl $0x6A0, %eax                /* PAE | PGE | OSFXSR | OSXMMEXCPT */
    movl %eax, %cr4
    movl $0xC0000080, %ecx          /* EFER.LME */
    rdmsr
    orl $0x100, %eax
    wrmsr
    movl %cr0, %eax
    orl $0x80000001, %eax           /* PG | PE */
    andl $0xFFFFFFFB, %eax          /* clear EM */
    orl $2, %eax                    /* MP */
    movl %eax, %cr0
    lgdt gdt64_ptr
    ljmp $0x08, $long_mode

    .code64
long_mode:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorl %eax, %eax
    movw %ax, %fs
    movw %ax, %gs
    movq $boot_stack_top, %rsp
    xorq %rbp, %rbp
    movl %esi, %edi
    movq %rdi, mbi_ptr
    fninit
    call kmain
hang:
    cli
    hlt
    jmp hang

    .section .note.GNU-stack, "", @progbits
