/* The CPU layer's assembly: entering ring 3, trap entry (interrupts, exceptions, SYSCALL) and the SYSCALL
 * entry used by the kernel's own libc. A trap from ring 3 saves the thread's registers into its context
 * and *returns from enter_user()*: the kernel is an ordinary loop that calls enter_user() and then looks
 * at what happened - there is no kernel code running "inside" an interrupt. */
#include "cpu_defs.h"

    .section .text

/* int enter_user(Ctx *ctx): run the thread until its next trap; returns the vector (256 = SYSCALL) */
    .global enter_user
enter_user:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, %gs:PC_KCTX_RSP
    movq %rdi, %gs:PC_CUR_CTX
    movq CTX_CR3(%rdi), %rax
    movq %cr3, %rdx
    cmpq %rax, %rdx
    je 1f
    movq %rax, %cr3
1:  movl $0xC0000100, %ecx              /* IA32_FS_BASE */
    movl CTX_FSB(%rdi), %eax
    movl CTX_FSB+4(%rdi), %edx
    wrmsr
    fxrstor CTX_FX(%rdi)
    pushq CTX_SS(%rdi)
    pushq CTX_RSP(%rdi)
    pushq CTX_RFLAGS(%rdi)
    pushq CTX_CS(%rdi)
    pushq CTX_RIP(%rdi)
    movq CTX_RAX(%rdi), %rax
    movq CTX_RBX(%rdi), %rbx
    movq CTX_RCX(%rdi), %rcx
    movq CTX_RDX(%rdi), %rdx
    movq CTX_RSI(%rdi), %rsi
    movq CTX_RBP(%rdi), %rbp
    movq CTX_R8(%rdi), %r8
    movq CTX_R9(%rdi), %r9
    movq CTX_R10(%rdi), %r10
    movq CTX_R11(%rdi), %r11
    movq CTX_R12(%rdi), %r12
    movq CTX_R13(%rdi), %r13
    movq CTX_R14(%rdi), %r14
    movq CTX_R15(%rdi), %r15
    movq CTX_RDI(%rdi), %rdi
    swapgs
    iretq

/* every interrupt/exception stub lands here with [vec][err][rip][cs][rflags][rsp][ss] on the stack */
    .global isr_common
isr_common:
    testb $3, 24(%rsp)
    jz kernel_trap
    swapgs
save_user:
    pushq %rax
    movq %gs:PC_CUR_CTX, %rax
    movq %rbx, CTX_RBX(%rax)
    movq %rcx, CTX_RCX(%rax)
    movq %rdx, CTX_RDX(%rax)
    movq %rsi, CTX_RSI(%rax)
    movq %rdi, CTX_RDI(%rax)
    movq %rbp, CTX_RBP(%rax)
    movq %r8, CTX_R8(%rax)
    movq %r9, CTX_R9(%rax)
    movq %r10, CTX_R10(%rax)
    movq %r11, CTX_R11(%rax)
    movq %r12, CTX_R12(%rax)
    movq %r13, CTX_R13(%rax)
    movq %r14, CTX_R14(%rax)
    movq %r15, CTX_R15(%rax)
    popq %rdx
    movq %rdx, CTX_RAX(%rax)
    popq CTX_VEC(%rax)
    popq CTX_ERR(%rax)
    popq CTX_RIP(%rax)
    popq CTX_CS(%rax)
    popq CTX_RFLAGS(%rax)
    popq CTX_RSP(%rax)
    popq CTX_SS(%rax)
    movq %cr2, %rdx
    movq %rdx, CTX_CR2(%rax)
    fxsave CTX_FX(%rax)
    movl $0xC0000100, %ecx              /* back to the kernel's own FS base (libc's thread pointer) */
    movl %gs:PC_KFS, %eax
    movl %gs:PC_KFS+4, %edx
    wrmsr
    movq %gs:PC_KCTX_RSP, %rsp
    movq %gs:PC_CUR_CTX, %rax
    movl CTX_VEC(%rax), %eax
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret

/* a trap while already in the kernel: an IRQ during idle (acknowledge and go on) or a kernel bug */
kernel_trap:
    cmpq $32, (%rsp)
    jb 1f
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    movq 72(%rsp), %rdi                 /* the vector */
    pushq %rbp
    movq %rsp, %rbp
    andq $-16, %rsp                     /* 16-byte aligned for the call */
    call kernel_irq
    movq %rbp, %rsp
    popq %rbp
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rax
    addq $16, %rsp
    iretq
1:  movq (%rsp), %rdi
    movq 8(%rsp), %rsi
    movq 16(%rsp), %rdx
    movq %cr2, %rcx
    andq $-16, %rsp
    call exception_report
2:  cli
    hlt
    jmp 2b

/* ---- SYSCALL: from ring 3 (rflags.IF was set) it is a thread trap; from our own ring 0 libc it is a call ---- */
    .global syscall_entry
syscall_entry:
    btl $9, %r11d
    jnc kernel_syscall
    swapgs
    movq %rsp, %gs:PC_USCRATCH
    movq %gs:PC_RSP0, %rsp
    pushq $SEL_UDATA
    pushq %gs:PC_USCRATCH
    pushq %r11
    pushq $SEL_UCODE
    pushq %rcx
    pushq $0
    pushq $TRAP_SYSCALL
    jmp save_user

kernel_syscall:
    subq $128, %rsp                     /* the caller may be using its red zone */
    pushq %rcx
    pushq %r11
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %rbp
    movq %rsp, %rbp
    andq $-16, %rsp
    pushq %r9
    pushq %r9
    movq %r8, %r9
    movq %r10, %r8
    movq %rdx, %rcx
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq %rax, %rdi
    call ksyscall
    movq %rbp, %rsp
    popq %rbp
    popq %r10
    popq %r9
    popq %r8
    popq %rdx
    popq %rsi
    popq %rdi
    popq %r11
    popq %rcx
    addq $128, %rsp
    pushq %r11
    popfq
    jmpq *%rcx

    .section .note.GNU-stack, "", @progbits
