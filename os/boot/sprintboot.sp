# Sprint OS bootloader, written and assembled entirely in Sprint (no GRUB, no external assembler).
#
#   stage 1  MBR (512 bytes): reads stage 2 with INT 13h extensions
#   stage 2  real mode: A20, VBE 1024x768x32 linear framebuffer, ACPI RSDP search, E820 memory map, a Multiboot2 info structure,
#            then the kernel's PT_LOAD segments are read from disk into memory above 1 MiB through a bounce buffer ("unreal" mode
#            gives ES a flat 4 GiB limit for the copy), and finally 32-bit protected mode -> the kernel's Multiboot2 entry point
#            (eax = 0x36d76289, ebx = the info structure), exactly what GRUB provides.
#
# The kernel ELF is parsed here, at image-build time: the image holds each segment on its own sector boundary and stage 2 carries a
# small load table (lba, destination, file size, memory size), so the 16-bit loader never has to understand ELF.
#
# usage: sprint run --allow-read=DIR --allow-write=DIR os/boot/sprintboot.sp KERNEL32.ELF OUT.IMG "kernel command line"
import asm
import fs
import sys

let kernel_path = sys.args[0]
let out_path = sys.args[1]
let cmdline = sys.args[2] if len(sys.args) > 2 else "init=boot"
let STAGE2_SECTORS = 8

# ---- the kernel's loadable segments --------------------------------------------------------------
let elf = fs.read_bytes(kernel_path)
func u32(off):
    return elf[off] | (elf[off + 1] << 8) | (elf[off + 2] << 16) | (elf[off + 3] << 24)
func u16(off):
    return elf[off] | (elf[off + 1] << 8)
if elf[0] != 0x7f or elf[1] != 0x45 or elf[4] != 1:
    throw error("ValueError", kernel_path .. " is not a 32-bit ELF file (objcopy -O elf32-i386)")
let entry = u32(24)
let phoff = u32(28)
let phentsize = u16(42)
let phnum = u16(44)
let segs = []
for i in range(phnum):
    let ph = phoff + i * phentsize
    if u32(ph) == 1:   # PT_LOAD
        segs.append({off: u32(ph + 4), paddr: u32(ph + 12), filesz: u32(ph + 16), memsz: u32(ph + 20)})

# image layout: sector 0 = stage 1, sectors 1.. = stage 2, then every segment on a sector boundary
let next_lba = 1 + STAGE2_SECTORS
let table = ""
for s in segs:
    s.lba = next_lba
    next_lba += (s.filesz + 511) // 512
    table = table .. "    dd " .. to_string(s.lba) .. ", " .. to_string(s.paddr) .. ", " .. to_string(s.filesz) .. ", " .. to_string(s.memsz) .. "\n"

func db_string(s):
    let parts = []
    for i in range(len(s)):
        parts.append(to_string(s[i]))
    return "db " .. parts.join(", ") .. ", 0"

# ---- stage 1 ----------------------------------------------------------------------------------------
let stage1 = """
bits 16
org 0x7c00
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    mov [drive], dl
    mov si, dap
    mov ah, 0x42
    int 0x13
    jc fail
    mov dl, [drive]
    jmp 0x0000:0x8000
fail:
    mov si, msg
.p: lodsb
    test al, al
    jz .h
    mov ah, 0x0e
    xor bx, bx
    int 0x10
    jmp .p
.h: hlt
    jmp .h
drive: db 0
dap: db 0x10, 0
    dw """ .. to_string(STAGE2_SECTORS) .. """
    dw 0x8000, 0
    dq 1
msg: db "stage 2: disk error", 0
"""

# ---- stage 2 ----------------------------------------------------------------------------------------
let cmd_tag = 8 + len(cmdline) + 1
let stage2 = """
bits 16
org 0x8000
stage2:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    mov [drive], dl
    mov si, msg_boot
    call puts
    in al, 0x92                     ; A20
    or al, 2
    and al, 0xfe
    out 0x92, al

    ; ---- VBE: a 1024x768x32 linear framebuffer ----
    mov ax, 0x4000
    mov es, ax
    xor di, di
    mov dword [es:di], 0x32454256   ; 'VBE2'
    mov ax, 0x4f00
    int 0x10
    cmp ax, 0x004f
    jne .novbe
    mov si, [es:0x0e]               ; copy the mode list next to the buffers (the BIOS may move its segments)
    mov ax, [es:0x10]
    mov fs, ax
    mov di, 0x400
    mov cx, 120
.cpml:
    mov ax, [fs:si]
    mov [es:di], ax
    add si, 2
    add di, 2
    cmp ax, 0xffff
    je .modes
    loop .cpml
.modes:
    mov bp, 0x400
.try:
    mov cx, [es:bp]
    cmp cx, 0xffff
    je .novbe
    add bp, 2
    mov ax, 0x4f01
    mov di, 0x200
    int 0x10
    cmp ax, 0x004f
    jne .try
    mov ax, [es:0x200]
    and ax, 0x81
    cmp ax, 0x81
    jne .try
    cmp word [es:0x212], 1024
    jne .try
    cmp word [es:0x214], 768
    jne .try
    cmp byte [es:0x219], 32
    jne .try
    cmp byte [es:0x21b], 6
    jne .try
    mov bx, cx
    or bx, 0x4000
    mov ax, 0x4f02
    int 0x10
    cmp ax, 0x004f
    jne .novbe
    mov eax, [es:0x228]
    mov [fb_addr], eax
    movzx eax, word [es:0x210]
    mov [fb_pitch], eax
    mov dword [fb_w], 1024
    mov dword [fb_h], 768
    mov byte [fb_bpp], 32
    mov al, [es:0x220]
    mov [fb_col + 0], al
    mov al, [es:0x21f]
    mov [fb_col + 1], al
    mov al, [es:0x222]
    mov [fb_col + 2], al
    mov al, [es:0x221]
    mov [fb_col + 3], al
    mov al, [es:0x224]
    mov [fb_col + 4], al
    mov al, [es:0x223]
    mov [fb_col + 5], al
    mov byte [have_fb], 1
.novbe:
    xor ax, ax
    mov es, ax

    ; ---- ACPI RSDP: the first KiB of the EBDA, then 0xE0000..0xFFFFF ----
    mov ax, [0x40e]
    test ax, ax
    jz .bios
    mov fs, ax
    xor si, si
    mov cx, 64
    call scan_rsdp
    jnc .rsdp
.bios:
    mov ax, 0xe000                  ; the BIOS area is 128 KiB: two 64 KiB segments
    mov fs, ax
    xor si, si
    mov cx, 4096
    call scan_rsdp
    jnc .rsdp
    mov ax, 0xf000
    mov fs, ax
    xor si, si
    mov cx, 4096
    call scan_rsdp
    jc .nordsp
.rsdp:
    mov di, rsdp_buf
    mov cx, 36
.cprs:
    mov al, [fs:si]
    mov [di], al
    inc si
    inc di
    dec cx
    jnz .cprs
    mov byte [have_rsdp], 1
.nordsp:

    ; ---- the Multiboot2 information structure at 0x30000 ----
    mov ax, 0x3000
    mov es, ax
    xor di, di
    mov dword [es:di], 0
    mov dword [es:di + 4], 0
    add di, 8
    mov dword [es:di], 1            ; command line
    mov dword [es:di + 4], """ .. to_string(cmd_tag) .. """
    mov si, cmdline
    mov cx, """ .. to_string(len(cmdline) + 1) .. """
    push di
    add di, 8
.cpcmd:
    mov al, [si]
    mov [es:di], al
    inc si
    inc di
    loop .cpcmd
    pop di
    add di, """ .. to_string((cmd_tag + 7) // 8 * 8) .. """
    mov bp, di                      ; memory map: E820, 24-byte entries
    mov dword [es:di], 6
    mov dword [es:di + 8], 24
    mov dword [es:di + 12], 0
    add di, 16
    xor ebx, ebx
.e820:
    mov dword [es:di + 20], 1
    mov eax, 0xe820
    mov edx, 0x534d4150
    mov ecx, 24
    int 0x15
    jc .e820done
    cmp eax, 0x534d4150
    jne .e820done
    mov dword [es:di + 20], 0
    add di, 24
    test ebx, ebx
    jnz .e820
.e820done:
    mov ax, di
    sub ax, bp
    movzx eax, ax
    mov [es:bp + 4], eax
    add di, 7
    and di, 0xfff8
    cmp byte [have_fb], 0
    je .nofb
    mov bp, di
    mov dword [es:di], 8            ; framebuffer
    mov dword [es:di + 4], 38
    mov eax, [fb_addr]
    mov [es:di + 8], eax
    mov dword [es:di + 12], 0
    mov eax, [fb_pitch]
    mov [es:di + 16], eax
    mov eax, [fb_w]
    mov [es:di + 20], eax
    mov eax, [fb_h]
    mov [es:di + 24], eax
    mov byte [es:di + 28], 32
    mov byte [es:di + 29], 1
    mov word [es:di + 30], 0
    mov si, fb_col
    mov cx, 6
    add di, 32
.cpcol:
    mov al, [si]
    mov [es:di], al
    inc si
    inc di
    loop .cpcol
    add di, 2
.nofb:
    cmp byte [have_rsdp], 0
    je .nors
    mov dword [es:di], 14           ; ACPI RSDP (old, 20 bytes)
    mov dword [es:di + 4], 28
    mov si, rsdp_buf
    mov cx, 20
    add di, 8
.cprs2:
    mov al, [si]
    mov [es:di], al
    inc si
    inc di
    loop .cprs2
    add di, 4
.nors:
    mov dword [es:di], 0            ; end tag
    mov dword [es:di + 4], 8
    add di, 8
    movzx eax, di
    mov [es:0], eax
    xor ax, ax
    mov es, ax

    ; ---- load the kernel segments ----
    mov si, msg_load
    call puts
    mov si, ktable
    mov cx, """ .. to_string(len(segs)) .. """
.seg:
    mov [ent], si
    mov [segs_left], cx
    mov eax, [si]
    mov [lba], eax
    mov eax, [si + 4]
    mov [dest], eax
    mov [dest0], eax
    mov eax, [si + 8]
    mov [filesz], eax
    mov eax, [si + 12]
    mov [memsz], eax
    mov eax, [filesz]
    add eax, 511
    shr eax, 9
    mov [left], eax
.chunk:
    mov eax, [left]
    test eax, eax
    jz .zero
    cmp eax, 64
    jbe .go
    mov eax, 64
.go:
    mov [nsec], ax
    mov [dap_count], ax
    mov eax, [lba]
    mov [dap_lba], eax
    mov si, dap
    mov dl, [drive]
    mov ah, 0x42
    sti
    int 0x13
    jc disk_error
    call unreal                     ; ES gets a flat 4 GiB limit (interrupts stay off until the copy is done)
    push ds
    mov ax, 0x5000
    mov ds, ax
    xor esi, esi
    mov edi, [cs:dest]
    movzx ecx, word [cs:nsec]
    shl ecx, 7                      ; sectors * 128 dwords
    db 0x67
    rep movsd
    pop ds
    movzx eax, word [nsec]
    mov ecx, eax
    shl eax, 9
    add [dest], eax
    add [lba], ecx
    sub [left], ecx
    jmp .chunk
.zero:
    mov ecx, [memsz]
    sub ecx, [filesz]
    jbe .nextseg
    call unreal
    mov edi, [dest0]
    add edi, [filesz]
    xor eax, eax
    db 0x67
    rep stosb
.nextseg:
    mov si, [ent]
    add si, 16
    mov cx, [segs_left]
    dec cx
    jnz .seg

    ; ---- protected mode, then the kernel (Multiboot2 entry convention) ----
    cli
    lgdt [gdt_ptr]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword 0x08:pm_entry

; ---- helpers (real mode) ----
puts:
    lodsb
    test al, al
    jz .d
    mov ah, 0x0e
    xor bx, bx
    int 0x10
    jmp puts
.d: ret

disk_error:
    mov si, msg_err
    call puts
.h: hlt
    jmp .h

unreal:
    cli
    push ds
    lgdt [gdt_ptr]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp .p
.p: mov bx, 0x10
    mov es, bx
    and eax, 0xfffffffe
    mov cr0, eax
    jmp .q
.q: pop ds
    ret

scan_rsdp:                          ; fs:si, cx paragraphs -> CF clear and fs:si at the RSDP
.l: cmp dword [fs:si], 0x20445352   ; 'RSD '
    jne .n
    cmp dword [fs:si + 4], 0x20525450   ; 'PTR '
    jne .n
    xor ax, ax
    xor bx, bx
.sum:
    add al, [fs:si + bx]
    inc bx
    cmp bx, 20
    jne .sum
    test al, al
    jz .ok
.n: add si, 16
    loop .l
    stc
    ret
.ok:
    clc
    ret

bits 32
pm_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax
    mov esp, 0x7000
    mov eax, 0x36d76289             ; Multiboot2 bootloader magic
    mov ebx, 0x30000                ; the information structure
    mov ecx, [kentry]
    jmp ecx

bits 16
align 8
gdt:
    dq 0
    dq 0x00cf9a000000ffff           ; 0x08 code, flat 4 GiB
    dq 0x00cf92000000ffff           ; 0x10 data, flat 4 GiB
gdt_end:
gdt_ptr:
    dw gdt_end - gdt - 1
    dd gdt

dap: db 0x10, 0
dap_count: dw 0
    dw 0x0000, 0x5000
dap_lba: dq 0
drive: db 0
have_fb: db 0
have_rsdp: db 0
fb_bpp: db 0
fb_col: db 0, 0, 0, 0, 0, 0
align 4
fb_addr: dd 0
fb_pitch: dd 0
fb_w: dd 0
fb_h: dd 0
lba: dd 0
dest: dd 0
dest0: dd 0
filesz: dd 0
memsz: dd 0
left: dd 0
nsec: dw 0
ent: dw 0
segs_left: dw 0
kentry: dd """ .. to_string(entry) .. """
msg_boot: """ .. db_string("Sprint OS bootloader (Sprint)\r\n") .. """
msg_load: """ .. db_string("loading kernel\r\n") .. """
msg_err: """ .. db_string("disk read error\r\n") .. """
cmdline: """ .. db_string(cmdline) .. """
align 4
ktable:
""" .. table .. """
rsdp_buf: times 36 db 0
"""

let s1 = asm.boot_sector(stage1, {})
let s2 = asm.assemble(stage2, {bits: 16, org: 0x8000})
if len(s2.bytes) > STAGE2_SECTORS * 512:
    throw error("ValueError", "stage 2 is " .. to_string(len(s2.bytes)) .. " bytes; raise STAGE2_SECTORS")
let img = []
for b in s1.bytes:
    img.append(b)
for b in s2.bytes:
    img.append(b)
while len(img) < (1 + STAGE2_SECTORS) * 512:
    img.append(0)
for s in segs:
    for i in range(s.filesz):
        img.append(elf[s.off + i])
    while len(img) % 512 != 0:
        img.append(0)
fs.write_bytes(out_path, img)
print("sprint bootloader: stage 2 " .. to_string(len(s2.bytes)) .. " bytes, " .. to_string(len(segs)) .. " segments, entry 0x" .. to_string(entry) .. ", image " .. to_string(len(img)) .. " bytes")
