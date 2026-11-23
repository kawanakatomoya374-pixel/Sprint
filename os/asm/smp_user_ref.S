# Reference: the __asm__ blocks of C-OS smp_user.c in GNU as syntax (extracted verbatim; the vector stubs are the APU_STUB_* macros expanded).
.text
.global apu_enter
apu_enter:
    pushq %rbx
 pushq %rbp
 pushq %r12
 pushq %r13
 pushq %r14
 pushq %r15
    movq %rsp, 0(%rdi)
    movq %cr3, %rax
    movq %rax, 8(%rdi)
    movq 0(%rsi), %rax
    movq %rax, %cr3
    movl $0xC0000100, %ecx
    movq 40(%rsi), %rax
    movq %rax, %rdx
 shrq $32, %rdx
 wrmsr
    movq 24(%rsi), %r8
    subq $8, %r8
    movq 32(%rsi), %rax
    movq %cr4, %rcx
    testl $0x200000, %ecx
    jz apu_nosmap_a
    .byte 0x0f, 0x01, 0xcb
apu_nosmap_a:
    movq %rax, (%r8)
    testl $0x200000, %ecx
    jz apu_nosmap_b
    .byte 0x0f, 0x01, 0xca
apu_nosmap_b:
    movq 8(%rsi), %r9
    movq 16(%rsi), %rdi
    movw $0x23, %ax
 movw %ax, %ds
 movw %ax, %es
    pushq $0x23
    pushq %r8
    pushq $0x202
    pushq $0x1B
    pushq %r9
    xorl %eax,%eax
 xorl %ebx,%ebx
 xorl %ecx,%ecx
 xorl %edx,%edx
 xorl %esi,%esi
    xorl %ebp,%ebp
 xorl %r8d,%r8d
 xorl %r9d,%r9d
 xorl %r10d,%r10d
 xorl %r11d,%r11d
    xorl %r12d,%r12d
 xorl %r13d,%r13d
 xorl %r14d,%r14d
 xorl %r15d,%r15d
    iretq
apu_common:
    testb $3, 24(%rsp)
    jnz 1f
    movw $0xE9, %dx
 movb $'!', %al
 outb %al, %dx
2:  cli
 hlt
 jmp 2b
1:  movq %rsp, %rax
    andq $-0x10000, %rax
    movq 0(%rsp), %rdx
    cmpq $0xD0, %rdx
 je 5f
    cmpq $0xE0, %rdx
 je 5f
    cmpq $0xF1, %rdx
 jne 6f
5:  movq 56(%rax), %rcx
    movl $0, 0xB0(%rcx)
    addq $16, %rsp
    iretq
6:  cmpq $0xFD, %rdx
    jne 3f
    movq 16(%rax), %rcx
    testq %rcx, %rcx
 jz 4f
    cmpl $0, 48(%rcx)
 je 4f
    jmp 3f
4:  movq 56(%rax), %rcx
    movl $0, 0xB0(%rcx)
    addq $16, %rsp
    iretq
3:  movq %rdx, 24(%rax)
    movq 8(%rsp), %rcx
 movq %rcx, 32(%rax)
    movq 16(%rsp), %rcx
 movq %rcx, 40(%rax)
    movq %cr2, %rcx
 movq %rcx, 48(%rax)
    movq 8(%rax), %rcx
 movq %rcx, %cr3
    movq 0(%rax), %rsp
    popq %r15
 popq %r14
 popq %r13
 popq %r12
 popq %rbp
 popq %rbx
    ret
apu_spurious:
    iretq
.text
apu_stub_0:
 pushq $0
 pushq $0
 jmp apu_common
.text
apu_stub_1:
 pushq $0
 pushq $1
 jmp apu_common
.text
apu_stub_2:
 pushq $0
 pushq $2
 jmp apu_common
.text
apu_stub_3:
 pushq $0
 pushq $3
 jmp apu_common
.text
apu_stub_4:
 pushq $0
 pushq $4
 jmp apu_common
.text
apu_stub_5:
 pushq $0
 pushq $5
 jmp apu_common
.text
apu_stub_6:
 pushq $0
 pushq $6
 jmp apu_common
.text
apu_stub_7:
 pushq $0
 pushq $7
 jmp apu_common
.text
apu_stub_8:
 pushq $8
 jmp apu_common
.text
apu_stub_9:
 pushq $0
 pushq $9
 jmp apu_common
.text
apu_stub_10:
 pushq $10
 jmp apu_common
.text
apu_stub_11:
 pushq $11
 jmp apu_common
.text
apu_stub_12:
 pushq $12
 jmp apu_common
.text
apu_stub_13:
 pushq $13
 jmp apu_common
.text
apu_stub_14:
 pushq $14
 jmp apu_common
.text
apu_stub_15:
 pushq $0
 pushq $15
 jmp apu_common
.text
apu_stub_16:
 pushq $0
 pushq $16
 jmp apu_common
.text
apu_stub_17:
 pushq $17
 jmp apu_common
.text
apu_stub_18:
 pushq $0
 pushq $18
 jmp apu_common
.text
apu_stub_19:
 pushq $0
 pushq $19
 jmp apu_common
.text
apu_stub_20:
 pushq $0
 pushq $20
 jmp apu_common
.text
apu_stub_21:
 pushq $21
 jmp apu_common
.text
apu_stub_22:
 pushq $0
 pushq $22
 jmp apu_common
.text
apu_stub_23:
 pushq $0
 pushq $23
 jmp apu_common
.text
apu_stub_24:
 pushq $0
 pushq $24
 jmp apu_common
.text
apu_stub_25:
 pushq $0
 pushq $25
 jmp apu_common
.text
apu_stub_26:
 pushq $0
 pushq $26
 jmp apu_common
.text
apu_stub_27:
 pushq $0
 pushq $27
 jmp apu_common
.text
apu_stub_28:
 pushq $0
 pushq $28
 jmp apu_common
.text
apu_stub_29:
 pushq $29
 jmp apu_common
.text
apu_stub_30:
 pushq $30
 jmp apu_common
.text
apu_stub_31:
 pushq $0
 pushq $31
 jmp apu_common
.text
apu_stub_208:
 pushq $0
 pushq $208
 jmp apu_common
.text
apu_stub_224:
 pushq $0
 pushq $224
 jmp apu_common
.text
apu_stub_241:
 pushq $0
 pushq $241
 jmp apu_common
.text
apu_stub_128:
 pushq $0
 pushq $128
 jmp apu_common
.text
apu_stub_130:
 pushq $0
 pushq $130
 jmp apu_common
.text
apu_stub_253:
 pushq $0
 pushq $253
 jmp apu_common
