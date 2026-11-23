# sha256_asm: SHA-256 in x86-64 assembly (assembled with the Sprint assembler), used by the UEFI loader to verify the kernel before it runs.
#
#   sha256_asm.text()   assembler source: sha256_all(rdi = context, rsi = data, rdx = length). The digest is left in the context as eight 32-bit
#                       words (state words, i.e. byte-swapped relative to the digest bytes). The routine keeps every register it touches (any
#                       x86-64 ABI) and needs only the context: a writable block of CTX_SIZE bytes.
#   sha256_asm.words(digest)   the same eight words from a 32-byte digest, for comparing
# os/boot/test_sha256.sp runs this code on the host against the native hash module.

export const CTX_SIZE = 448

const K = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
           0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
           0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
           0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
           0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
           0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
           0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
           0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
const H0 = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

func dd_list(xs):
    let parts = []
    for x in xs:
        parts.append(to_string(x))
    return "dd " .. parts.join(", ")

export func words(digest):
    let w = []
    for i in range(8):
        w.append((digest[4 * i] << 24) | (digest[4 * i + 1] << 16) | (digest[4 * i + 2] << 8) | digest[4 * i + 3])
    return w

export func text():
    return """
; context layout: H(32) W(256) tail(128) ptr rem total padlen (4 x 8)
sha256_block:                       ; rdi = context, rsi = 64-byte block
    push rbx
    push rbp
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15
    push rdi                        ; the context again (rdi becomes the schedule pointer)
    add rdi, 32
    xor ecx, ecx
.ld:
    mov eax, [rsi + rcx * 4]
    bswap eax
    mov [rdi + rcx * 4], eax
    inc ecx
    cmp ecx, 16
    jb .ld
.sc:
    mov eax, [rdi + rcx * 4 - 8]    ; W[t-2]
    mov edx, eax
    ror eax, 17
    mov ebx, edx
    ror ebx, 19
    xor eax, ebx
    shr edx, 10
    xor eax, edx
    add eax, [rdi + rcx * 4 - 28]   ; W[t-7]
    mov edx, [rdi + rcx * 4 - 60]   ; W[t-15]
    mov ebx, edx
    ror edx, 7
    mov esi, ebx
    ror esi, 18
    xor edx, esi
    shr ebx, 3
    xor edx, ebx
    add eax, edx
    add eax, [rdi + rcx * 4 - 64]   ; W[t-16]
    mov [rdi + rcx * 4], eax
    inc ecx
    cmp ecx, 64
    jb .sc
    mov rax, [rsp]                  ; the context: load the state
    mov r8d, [rax]
    mov r9d, [rax + 4]
    mov r10d, [rax + 8]
    mov r11d, [rax + 12]
    mov r12d, [rax + 16]
    mov r13d, [rax + 20]
    mov r14d, [rax + 24]
    mov r15d, [rax + 28]
    lea rbp, [sha_k]
    xor ecx, ecx
.rd:
    mov eax, r12d                   ; T1 = h + S1(e) + Ch(e, f, g) + K[t] + W[t]
    ror eax, 6
    mov ebx, r12d
    ror ebx, 11
    xor eax, ebx
    mov ebx, r12d
    ror ebx, 25
    xor eax, ebx
    add eax, r15d
    mov ebx, r12d
    and ebx, r13d
    mov edx, r12d
    not edx
    and edx, r14d
    xor ebx, edx
    add eax, ebx
    add eax, [rbp + rcx * 4]
    add eax, [rdi + rcx * 4]
    mov ebx, r8d                    ; T2 = S0(a) + Maj(a, b, c)
    ror ebx, 2
    mov edx, r8d
    ror edx, 13
    xor ebx, edx
    mov edx, r8d
    ror edx, 22
    xor ebx, edx
    mov edx, r8d
    and edx, r9d
    mov esi, r8d
    and esi, r10d
    xor edx, esi
    mov esi, r9d
    and esi, r10d
    xor edx, esi
    add ebx, edx
    mov r15d, r14d                  ; h = g, g = f, f = e, e = d + T1, d = c, c = b, b = a, a = T1 + T2
    mov r14d, r13d
    mov r13d, r12d
    mov r12d, r11d
    add r12d, eax
    mov r11d, r10d
    mov r10d, r9d
    mov r9d, r8d
    lea r8d, [rax + rbx]
    inc ecx
    cmp ecx, 64
    jb .rd
    pop rax                         ; the context: add the working variables to the state
    add [rax], r8d
    add [rax + 4], r9d
    add [rax + 8], r10d
    add [rax + 12], r11d
    add [rax + 16], r12d
    add [rax + 20], r13d
    add [rax + 24], r14d
    add [rax + 28], r15d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbp
    pop rbx
    ret

sha256_all:                         ; rdi = context, rsi = data, rdx = length
    push rbx
    push rbp
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov [rbx + 416], rsi
    mov [rbx + 424], rdx
    mov [rbx + 432], rdx
    lea rsi, [sha_h0]               ; the initial state
    mov rdi, rbx
    mov ecx, 8
    cld
    rep movsd
.full:
    cmp qword [rbx + 424], 64
    jb .tail
    mov rdi, rbx
    mov rsi, [rbx + 416]
    call sha256_block
    add qword [rbx + 416], 64
    sub qword [rbx + 424], 64
    jmp .full
.tail:
    lea rdi, [rbx + 288]            ; the last block(s): the rest, 0x80, zeros, the 64-bit big-endian bit length
    xor eax, eax
    mov ecx, 32
    rep stosd
    mov rsi, [rbx + 416]
    lea rdi, [rbx + 288]
    mov rcx, [rbx + 424]
    rep movsb
    mov byte [rdi], 0x80
    mov ecx, 64
    cmp qword [rbx + 424], 56
    jb .len
    mov ecx, 128
.len:
    mov rax, [rbx + 432]
    shl rax, 3
    bswap rax
    mov [rbx + rcx + 280], rax      ; tail + padded length - 8
    mov [rbx + 440], rcx
    mov rdi, rbx
    lea rsi, [rbx + 288]
    call sha256_block
    cmp qword [rbx + 440], 128
    jb .done
    mov rdi, rbx
    lea rsi, [rbx + 352]
    call sha256_block
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbp
    pop rbx
    ret

align 4
sha_h0: """ .. dd_list(H0) .. """
sha_k: """ .. dd_list(K) .. """
"""
