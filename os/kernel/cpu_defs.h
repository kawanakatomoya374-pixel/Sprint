/* Layouts shared by the C and assembly parts of the CPU layer. */
#ifndef OS_CPU_DEFS_H
#define OS_CPU_DEFS_H

/* per-CPU block (GS base while in the kernel) */
#define PC_SELF 0
#define PC_KCTX_RSP 8
#define PC_CUR_CTX 16
#define PC_RSP0 24
#define PC_USCRATCH 32
#define PC_ID 40
#define PC_KFS 48
#define PC_SIZE 128

/* thread context: what a thread's CPU state looks like while it is not running in ring 3 */
#define CTX_RAX 0
#define CTX_RBX 8
#define CTX_RCX 16
#define CTX_RDX 24
#define CTX_RSI 32
#define CTX_RDI 40
#define CTX_RBP 48
#define CTX_R8 56
#define CTX_R9 64
#define CTX_R10 72
#define CTX_R11 80
#define CTX_R12 88
#define CTX_R13 96
#define CTX_R14 104
#define CTX_R15 112
#define CTX_RIP 120
#define CTX_RSP 128
#define CTX_RFLAGS 136
#define CTX_CS 144
#define CTX_SS 152
#define CTX_VEC 160
#define CTX_ERR 168
#define CTX_CR2 176
#define CTX_FSB 184
#define CTX_CR3 192
#define CTX_FX 256 /* 512-byte FXSAVE area, 16-byte aligned */
#define CTX_SIZE 768

#define SEL_KCODE 0x08
#define SEL_KDATA 0x10
#define SEL_UDATA 0x1B
#define SEL_UCODE 0x23
#define TRAP_SYSCALL 256

#endif
