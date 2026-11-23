# smp_user: the assembly of C-OS's smp_user.c (ring3 compute jobs on application processors) written for the Sprint assembler.
# It replaces the __asm__ blocks of that file: apu_enter, the common landing apu_common, apu_spurious and one stub per vector.
#
#   build/sprint run --allow-write=build os/asm/smp_user.sp build/smp_user.bin     # writes the machine code (and prints the symbols)
#
# Intel syntax, and plain enough for NASM as well (os/asm/check.sh assembles it with the Sprint assembler, NASM and GNU as and
# compares the bytes).
import asm
import fs
import str
import sys

# vectors whose exception pushes an error code (the others get a dummy 0 pushed first)
const ERR_VECTORS = [8, 10, 11, 12, 13, 14, 17, 21, 29, 30]
const STUB_VECTORS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 208, 224, 241, 128, 130, 253]

const MAIN = """
bits 64
apu_enter:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov [rdi], rsp
    mov rax, cr3
    mov [rdi+8], rax
    mov rax, [rsi]
    mov cr3, rax
    mov ecx, 0xC0000100          ; IA32_FS_BASE
    mov rax, [rsi+40]
    mov rdx, rax
    shr rdx, 32
    wrmsr
    mov r8, [rsi+24]
    sub r8, 8
    mov rax, [rsi+32]
    mov rcx, cr4
    test ecx, 0x200000           ; CR4.SMAP: only then may (and must) AC be set; stac/clac are #UD on a CPU without SMAP
    jz apu_nosmap_a
    db 0x0f, 0x01, 0xcb          ; stac
apu_nosmap_a:
    mov [r8], rax                ; return address = exit stub
    test ecx, 0x200000
    jz apu_nosmap_b
    db 0x0f, 0x01, 0xca          ; clac
apu_nosmap_b:
    mov r9, [rsi+8]
    mov rdi, [rsi+16]
    mov ax, 0x23
    mov ds, ax
    mov es, ax
    push 0x23                    ; SS
    push r8                      ; RSP
    push 0x202                   ; RFLAGS: IF=1 so the kill IPI lands
    push 0x1B                    ; CS
    push r9                      ; RIP
    xor eax, eax
    xor ebx, ebx
    xor ecx, ecx
    xor edx, edx
    xor esi, esi
    xor ebp, ebp
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    xor r12d, r12d
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d
    iretq
; Common landing for every vector. Stack: vec, err, rip, cs, rflags, rsp, ss.
apu_common:
    test byte [rsp+24], 3        ; CS.RPL == 0: a kernel-mode fault; no way back
    jnz apu_user
    mov dx, 0xE9
    mov al, '!'
    out dx, al
apu_halt:
    cli
    hlt
    jmp apu_halt
apu_user:
    mov rax, rsp
    and rax, -0x10000            ; rax = ctx
    mov rdx, [rsp]               ; vector
    cmp rdx, 0xD0                ; the scheduler tick, kick and TLB IPIs (0xD0, 0xE0, 0xF1) can arrive just as a job starts:
    je apu_eoi_resume            ; acknowledge and resume it (leaving one in service would stop this CPU's timer for good)
    cmp rdx, 0xE0
    je apu_eoi_resume
    cmp rdx, 0xF1
    jne apu_not_ipi
apu_eoi_resume:
    mov rcx, [rax+56]
    mov dword [rcx+0xB0], 0
    add rsp, 16
    iretq
apu_not_ipi:
    cmp rdx, 0xFD
    jne apu_leave
    mov rcx, [rax+16]            ; job
    test rcx, rcx
    jz apu_kill_ignored
    cmp dword [rcx+48], 0
    je apu_kill_ignored          ; kill IPI with no kill request: ignore
    jmp apu_leave
apu_kill_ignored:
    mov rcx, [rax+56]
    mov dword [rcx+0xB0], 0      ; EOI, then resume the interrupted job
    add rsp, 16
    iretq
apu_leave:
    mov [rax+24], rdx
    mov rcx, [rsp+8]
    mov [rax+32], rcx
    mov rcx, [rsp+16]
    mov [rax+40], rcx
    mov rcx, cr2
    mov [rax+48], rcx
    mov rcx, [rax+8]
    mov cr3, rcx                 ; back on the kernel's page tables
    mov rsp, [rax]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
apu_spurious:
    iretq
"""

export func source():
    let s = MAIN
    for v in STUB_VECTORS:
        s = s .. "apu_stub_" .. to_string(v) .. ":\n"
        if not ERR_VECTORS.contains(v):
            s = s .. "    push 0\n"
        s = s .. "    push " .. to_string(v) .. "\n    jmp apu_common\n"
    return s

export func build():
    return asm.assemble(source(), {bits: 64, org: 0})

if len(sys.args) > 0:
    let r = build()
    fs.write_bytes(sys.args[0], r.bytes)
    if len(sys.args) > 1:
        fs.write_bytes(sys.args[1], str.to_bytes(source()))
    print(len(r.bytes), "bytes")
