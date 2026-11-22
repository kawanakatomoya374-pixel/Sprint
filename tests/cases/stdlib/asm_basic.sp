# the Sprint x86 assembler: encodings (verified against NASM by tools/asm/check.py), labels, directives, errors
import asm

let D = "0123456789abcdef"
func hx(bytes):
    let s = ""
    for b in bytes:
        s = s .. D.slice(b // 16, b // 16 + 1) .. D.slice(b % 16, b % 16 + 1)
    return s

func show(src, bits = 16):
    print(hx(asm.assemble(src, {bits: bits}).bytes))

# real mode
show("mov ax, 0x1234\nmov bx, ax\nadd ax, 5\nxor cx, cx\nmov ds, ax\nint 0x10\nhlt")
show("mov [bx+si+4], al\nmov ax, [es:di]\nlea si, [bp-2]\nmov al, [0x1234]")
show("jmp dword 0x08:0x8000\ncli\nlgdt [0x7c00]\nmov eax, cr0\nor eax, 1\nmov cr0, eax")
# forward / backward jumps pick short or near forms over several passes
show("start: nop\n jmp fwd\n times 130 nop\nfwd: jne start\n jmp short start")
show("top: dec cx\n jnz top\n loop top\n call top\n ret")
# protected mode and long mode
show("mov eax, [ebx+ecx*4+8]\npush dword 5\nmovzx eax, byte [esi]\nshl edx, 3\nrep movsd\nxchg eax, ecx", 32)
show("mov rax, 0x123456789abc\nmov r9, rsp\nadd r10, [rbx+r12*8+0x10]\nlea rdi, [rel $]\nsyscall\nmov sil, 5\ncqo", 64)
show("mov rax, [rip+0x10]\npush rbp\npop r15\nmovsxd rax, ecx\nbswap r11\nmov cr3, rax\ncall rax", 64)
# directives
let r = asm.assemble("""
org 0x7c00
begin:
msg: db "Hi", 0
.len equ $ - msg
n equ 3 * 4
value: dw n, begin, msg
dd 0x01020304
dq 1
times 4 db 0xaa
resb 2
align 8, db 0
end:
""", {bits: 16})
print(hx(r.bytes), r.symbols["begin"], r.symbols["msg"], r.symbols["n"], r.symbols["value"], r.symbols["end"])
# a boot sector is exactly 512 bytes and ends in the 0x55 0xaa signature
let bs = asm.boot_sector("cli\nhlt\n")
print(len(bs.bytes), bs.bytes[510], bs.bytes[511], hx(bs.bytes.slice(0, 2)))
# %define and local labels
show("%define PORT 0x60\n in al, PORT\n.a: nop\nf: nop\n.a: nop\n jmp f.a")
# errors
for src in ["frobnicate ax", "mov ax, bl", "mov [bx], 5", "jmp nowhere", "mov rax, 1", "add ax, [bx", "push ax, bx", "mov ah, spl"]:
    try:
        asm.assemble(src, {bits: 16})
        print("accepted", src)
    catch e:
        print(e.kind, e.message)
