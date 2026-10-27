/* Application-processor start-up code. The BSP copies [ap_tramp_start, ap_tramp_end) to physical 0x8000 and sends
 * INIT + SIPI(vector 8); the AP starts in 16-bit real mode there and climbs to 64-bit mode with the kernel's
 * page tables, then calls ap_main(index) on its own stack. The four words at ap_data are filled in per CPU. */
#define T(sym) (0x8000 + (sym) - ap_tramp_start)
    .section .rodata
    .balign 16
    .global ap_tramp_start
    .global ap_tramp_end
    .global ap_data
ap_tramp_start:
    .code16
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    lgdtl T(ap_gdtr)
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    ljmpl $0x08, $T(ap_pm32)
    .code32
ap_pm32:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movl %cr4, %eax
    orl $0x6A0, %eax
    movl %eax, %cr4
    movl T(ap_data), %eax          /* pml4 (32-bit physical) */
    movl %eax, %cr3
    movl $0xC0000080, %ecx
    rdmsr
    orl $0x100, %eax               /* EFER.LME */
    wrmsr
    movl %cr0, %eax
    orl $0x80000003, %eax          /* PG | MP | PE */
    andl $0xFFFFFFFB, %eax         /* clear EM */
    movl %eax, %cr0
    ljmpl $0x18, $T(ap_lm64)
    .code64
ap_lm64:
    xorl %eax, %eax
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    fninit
    movq T(ap_data + 8), %rsp      /* stack top */
    movq T(ap_data + 24), %rdi     /* cpu index */
    movq T(ap_data + 16), %rax     /* ap_main */
    callq *%rax
1:  hlt
    jmp 1b
    .balign 16
ap_gdt:
    .quad 0
    .quad 0x00CF9A000000FFFF       /* 0x08 code32 */
    .quad 0x00CF92000000FFFF       /* 0x10 data */
    .quad 0x00AF9A000000FFFF       /* 0x18 code64 */
ap_gdtr:
    .word 4 * 8 - 1
    .long T(ap_gdt)
    .balign 16
ap_data:
    .quad 0                        /* +0  pml4 */
    .quad 0                        /* +8  stack top */
    .quad 0                        /* +16 entry */
    .quad 0                        /* +24 cpu index */
ap_tramp_end:
    .section .note.GNU-stack, "", @progbits
