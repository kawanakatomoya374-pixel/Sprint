# uefi_loader: the Sprint OS UEFI loader and kernel file (see uefiboot.sp for the description), as a module so that the plain UEFI
# image and the hybrid BIOS + UEFI image share it.
#
#   let u = uefi_loader.build(elf_bytes, info, "init=boot")
#   u.efi      \EFI\BOOT\BOOTX64.EFI (a PE32+ file)
#   u.kbin     \SPRINTOS.BIN: the kernel's PT_LOAD segments, concatenated
import asm
import typed
import uefi_pe

func u16s(s):
    let parts = []
    for i in range(len(s)):
        parts.append(to_string(s[i]))
    return "dw " .. parts.join(", ") .. ", 0"

func db_string(s):
    let parts = []
    for i in range(len(s)):
        parts.append(to_string(s[i]))
    return "db " .. parts.join(", ") .. ", 0"


export func build(elf, info, cmdline):
    let entry = info.entry
    let segs = []
    let kbin_size = 0
    for i in range(len(info.segs)):
        let t = info.segs[i]
        segs.append({off: t.off, paddr: t.paddr, filesz: t.filesz, memsz: t.memsz, fileoff: kbin_size})
        kbin_size += t.filesz
    let kbin = typed.u8(kbin_size)
    for s in segs:
        for i in range(s.filesz):
            kbin[s.fileoff + i] = elf[s.off + i]
    let ktable = ""
    for s in segs:
        ktable = ktable .. "    dd " .. to_string(s.fileoff) .. ", " .. to_string(s.paddr) .. ", " .. to_string(s.filesz) .. ", " .. to_string(s.memsz) .. "\n"
    
    # ---- the trampoline: UEFI long mode -> 32-bit protected mode -> the kernel ------------------------------
    let tramp_src = """
    bits 64
    t64:
        cli
        lea rsp, [rel t_stack_top]
        lgdt [rel t_gdtptr]
        lea rbp, [rel t64]              ; the trampoline's own address, kept in ebp for the 32-bit part
        push 0x08
        lea rax, [rel t_compat]
        push rax
        retfq
    bits 32
    t_compat:
        mov ax, 0x10
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov fs, ax
        mov gs, ax
        mov eax, cr0
        and eax, 0x7fffffff             ; paging off (we run identity-mapped below 1 MiB)
        mov cr0, eax
        mov ecx, 0xc0000080             ; EFER
        rdmsr
        and eax, 0xfffffeff             ; long mode off
        wrmsr
        xor eax, eax
        mov cr4, eax
        ; the kernel's segments: copy from the file buffer to their addresses, zero the bss (no page tables to protect any more)
        lea ebx, [ebp + t_ktable]
        mov eax, [ebp + t_nseg]
        mov [ebp + t_cnt], eax
    .cs:
        mov esi, [ebx]
        add esi, [ebp + t_kbuf]
        mov edi, [ebx + 4]
        mov ecx, [ebx + 8]
        cld
        rep movsb
        mov edi, [ebx + 4]
        add edi, [ebx + 8]
        mov ecx, [ebx + 12]
        sub ecx, [ebx + 8]
        xor eax, eax
        rep stosb
        add ebx, 16
        dec dword [ebp + t_cnt]
        jnz .cs
        mov ebx, [ebp + t_mbi]
        mov edi, [ebp + t_entry]
        mov eax, 0x36d76289             ; Multiboot2 bootloader magic
        jmp edi
    align 8
    t_gdt:
        dq 0
        dq 0x00cf9a000000ffff
        dq 0x00cf92000000ffff
    t_gdtptr:
        dw 23
        dq 0
    t_mbi: dd 0
    t_entry: dd 0
    t_kbuf: dd 0
    t_nseg: dd """ .. to_string(len(segs)) .. """
    t_cnt: dd 0
    align 16
    t_ktable:
    """ .. ktable .. """
    times 256 db 0
    t_stack_top:
    """
    let tramp = asm.assemble(tramp_src, {bits: 64, org: 0})
    let TL = tramp.symbols
    
    # ---- the loader ------------------------------------------------------------------------------------------
    let cmd_tag = 8 + len(cmdline) + 1
    let kpages = (kbin_size + 4095) // 4096
    let app_src = """
    bits 64
    default rel
    efi_main:
        sub rsp, 56
        mov [image], rcx
        mov [systab], rdx
        mov rax, [rdx + 96]
        mov [bs], rax
        lea rdx, [msg_banner]
        call puts
    
        ; ---- GOP: a 1024x768 mode ----
        lea rcx, [guid_gop]
        xor edx, edx
        lea r8, [gop]
        mov rax, [bs]
        call [rax + 320]                ; LocateProtocol
        test rax, rax
        jnz .gopdone
        mov rbx, [gop]
        mov rax, [rbx + 24]
        mov r12d, [rax]                 ; Mode->MaxMode
        xor r13d, r13d
    .mode:
        cmp r13d, r12d
        jae .gopdone
        mov rcx, rbx
        mov edx, r13d
        lea r8, [modesz]
        lea r9, [modeinfo]
        call [rbx]                      ; QueryMode
        test rax, rax
        jnz .nextmode
        mov rax, [modeinfo]
        cmp dword [rax + 4], 1024
        jne .nextmode
        cmp dword [rax + 8], 768
        jne .nextmode
        cmp dword [rax + 12], 2         ; PixelFormat: RGB or BGR with 8 bits per channel
        jae .nextmode
        mov rcx, rbx
        mov edx, r13d
        call [rbx + 8]                  ; SetMode
        test rax, rax
        jnz .nextmode
        mov rax, [rbx + 24]
        mov rdx, [rax + 24]             ; FrameBufferBase
        mov [fb_addr], rdx
        mov rcx, [rax + 8]              ; Info
        mov edx, [rcx + 32]             ; PixelsPerScanLine
        shl edx, 2
        mov [fb_pitch], edx
        mov edx, [rcx + 12]
        mov [fb_fmt], edx
        mov byte [have_fb], 1
        jmp .gopdone
    .nextmode:
        inc r13d
        jmp .mode
    .gopdone:
    
        ; ---- ACPI RSDP from the configuration tables ----
        mov rax, [systab]
        mov rcx, [rax + 104]
        mov rsi, [rax + 112]
    .cfg:
        test rcx, rcx
        jz .cfgdone
        mov r8, [rsi]
        cmp r8, [guid_acpi]
        jne .cfgnext
        mov r8, [rsi + 8]
        cmp r8, [guid_acpi + 8]
        jne .cfgnext
        mov rsi, [rsi + 16]
        lea rdi, [rsdp_buf]
        mov ecx, 36
        cld
        rep movsb
        mov byte [have_rsdp], 1
        jmp .cfgdone
    .cfgnext:
        add rsi, 24
        dec rcx
        jmp .cfg
    .cfgdone:
    
        ; ---- read SPRINTOS.BIN from the volume this image came from ----
        mov qword [kbuf], 0xffffffff
        mov ecx, 1                      ; AllocateMaxAddress: below 4 GiB (the 32-bit copy reads it)
        mov edx, 2
        mov r8d, """ .. to_string(kpages) .. """
        lea r9, [kbuf]
        mov rax, [bs]
        call [rax + 40]
        test rax, rax
        jnz fail_kbuf
        mov rcx, [image]
        lea rdx, [guid_loaded]
        lea r8, [loaded]
        mov rax, [bs]
        call [rax + 152]                ; HandleProtocol(LoadedImage)
        test rax, rax
        jnz fail_file
        mov rax, [loaded]
        mov rcx, [rax + 24]             ; DeviceHandle
        lea rdx, [guid_sfs]
        lea r8, [sfs]
        mov rax, [bs]
        call [rax + 152]                ; HandleProtocol(SimpleFileSystem)
        test rax, rax
        jnz fail_file
        mov rcx, [sfs]
        lea rdx, [root]
        call [rcx + 8]                  ; OpenVolume
        test rax, rax
        jnz fail_file
        mov rcx, [root]
        lea rdx, [kfile]
        lea r8, [kname]
        mov r9d, 1                      ; read
        mov qword [rsp + 32], 0
        call [rcx + 8]                  ; Open
        test rax, rax
        jnz fail_file
        mov qword [ksize_v], """ .. to_string(kbin_size) .. """
        mov rcx, [kfile]
        lea rdx, [ksize_v]
        mov r8, [kbuf]
        call [rcx + 32]                 ; Read
        test rax, rax
        jnz fail_file
    
        ; ---- low memory (below 1 MiB) for the Multiboot2 information and the trampoline ----
        mov qword [mbi], 0xfffff
        mov ecx, 1                      ; AllocateMaxAddress
        mov edx, 2
        mov r8d, 8
        lea r9, [mbi]
        mov rax, [bs]
        call [rax + 40]
        test rax, rax
        jnz fail_low
        mov qword [tramp], 0xfffff
        mov ecx, 1
        mov edx, 2
        mov r8d, 1
        lea r9, [tramp]
        mov rax, [bs]
        call [rax + 40]
        test rax, rax
        jnz fail_low
        xor ecx, ecx
        mov edx, 2
        mov r8d, 16
        lea r9, [mmbuf]
        mov rax, [bs]
        call [rax + 40]
        test rax, rax
        jnz fail_alloc
    
        ; the trampoline: copy and patch
        lea rsi, [tramp_blob]
        mov rdi, [tramp]
        mov ecx, """ .. to_string(tramp.symbols["t_stack_top"]) .. """
        cld
        rep movsb
        mov rdi, [tramp]
        mov eax, [mbi]
        mov [rdi + """ .. to_string(TL["t_mbi"]) .. """], eax
        mov dword [rdi + """ .. to_string(TL["t_entry"]) .. """], """ .. to_string(entry) .. """
        mov eax, [kbuf]
        mov [rdi + """ .. to_string(TL["t_kbuf"]) .. """], eax
        lea rax, [rdi + """ .. to_string(TL["t_gdt"]) .. """]
        mov [rdi + """ .. to_string(TL["t_gdtptr"] + 2) .. """], rax
    
        ; ---- the Multiboot2 information structure: command line, framebuffer, RSDP; the memory map goes last ----
        mov rdi, [mbi]
        mov dword [rdi], 0
        mov dword [rdi + 4], 0
        add rdi, 8
        mov dword [rdi], 1
        mov dword [rdi + 4], """ .. to_string(cmd_tag) .. """
        mov r10, rdi
        lea rsi, [cmdline]
        add rdi, 8
        mov ecx, """ .. to_string(len(cmdline) + 1) .. """
        rep movsb
        mov rdi, r10
        add rdi, """ .. to_string((cmd_tag + 7) // 8 * 8) .. """
        cmp byte [have_fb], 0
        je .nofb
        mov dword [rdi], 8
        mov dword [rdi + 4], 38
        mov rax, [fb_addr]
        mov [rdi + 8], rax
        mov eax, [fb_pitch]
        mov [rdi + 16], eax
        mov dword [rdi + 20], 1024
        mov dword [rdi + 24], 768
        mov byte [rdi + 28], 32
        mov byte [rdi + 29], 1
        mov word [rdi + 30], 0
        mov byte [rdi + 33], 8
        mov byte [rdi + 35], 8
        mov byte [rdi + 37], 8
        mov byte [rdi + 34], 8
        cmp dword [fb_fmt], 1
        je .bgr
        mov byte [rdi + 32], 0          ; RGB: red at bit 0
        mov byte [rdi + 36], 16
        jmp .fbdone
    .bgr:
        mov byte [rdi + 32], 16         ; BGR: red at bit 16
        mov byte [rdi + 36], 0
    .fbdone:
        add rdi, 40
    .nofb:
        cmp byte [have_rsdp], 0
        je .nors
        mov dword [rdi], 15
        mov dword [rdi + 4], 44
        mov r10, rdi
        lea rsi, [rsdp_buf]
        add rdi, 8
        mov ecx, 36
        rep movsb
        mov rdi, r10
        add rdi, 48
    .nors:
        mov [mbi_cur], rdi
    
        ; ---- memory map, ExitBootServices (retry while the map key is stale) ----
    .retry:
        mov qword [mmsize], 65536
        lea rcx, [mmsize]
        mov rdx, [mmbuf]
        lea r8, [mmkey]
        lea r9, [descsz]
        lea rax, [descver]
        mov [rsp + 32], rax
        mov rax, [bs]
        call [rax + 56]                 ; GetMemoryMap
        test rax, rax
        jnz fail_mm
        mov rdi, [mbi_cur]
        mov r10, rdi
        mov dword [rdi], 6
        mov dword [rdi + 8], 24
        mov dword [rdi + 12], 0
        add rdi, 16
        mov rsi, [mmbuf]
        mov rax, [mmsize]
        xor edx, edx
        mov rcx, [descsz]
        div rcx
        mov [mmcount], rax
        mov r11, rax
    .conv:
        test r11, r11
        jz .convdone
        mov rax, [rsi + 8]
        mov [rdi], rax
        mov rax, [rsi + 24]
        shl rax, 12
        mov [rdi + 8], rax
        mov eax, [rsi]
        mov edx, 2
        cmp eax, 7                      ; conventional memory
        je .free
        cmp eax, 1                      ; loader / boot services code and data are free once boot services are gone
        jb .typed
        cmp eax, 4
        ja .typed
    .free:
        mov edx, 1
    .typed:
        mov [rdi + 16], edx
        mov dword [rdi + 20], 0
        add rdi, 24
        add rsi, [descsz]
        dec r11
        jmp .conv
    .convdone:
        mov rax, rdi
        sub rax, r10
        mov [r10 + 4], eax
        ; every kernel range (and nothing else we need) must be memory that is free once boot services are gone
        lea r14, [ktable]
        mov r15d, """ .. to_string(len(segs)) .. """
    .chkseg:
        mov r8d, [r14 + 4]
        mov r9d, [r14 + 12]
        add r9, r8
        mov rax, [kbuf]                 ; the file buffer must not overlap the destination
        mov rdx, rax
        add rdx, """ .. to_string(kpages * 4096) .. """
        cmp rax, r9
        jae .kbok
        cmp rdx, r8
        ja fail_range
    .kbok:
        mov rsi, [mmbuf]
        mov r11, [mmcount]
    .chkd:
        test r11, r11
        jz .chknext
        mov rax, [rsi + 8]
        mov rdx, [rsi + 24]
        shl rdx, 12
        add rdx, rax
        cmp rax, r9
        jae .chkdn
        cmp rdx, r8
        jbe .chkdn
        mov eax, [rsi]
        cmp eax, 7
        je .chkdn
        cmp eax, 1
        jb .bad
        cmp eax, 4
        jbe .chkdn
    .bad:
        push rax
        mov rax, [rsi + 8]
        call puthex
        mov rax, [rsi + 24]
        shl rax, 12
        call puthex
        pop rax
        call puthex
        jmp fail_range
    .chkdn:
        add rsi, [descsz]
        dec r11
        jmp .chkd
    .chknext:
        add r14, 16
        dec r15d
        jnz .chkseg
        mov rdi, [mbi_cur]
        mov rax, [mmcount]
        imul rax, 24
        lea rdi, [rdi + rax + 16]       ; the end tag follows the memory-map entries
        mov dword [rdi], 0              ; end tag
        mov dword [rdi + 4], 8
        add rdi, 8
        mov rax, rdi
        mov rcx, [mbi]
        sub rax, rcx
        mov [rcx], eax
        mov rcx, [image]
        mov rdx, [mmkey]
        mov rax, [bs]
        call [rax + 232]                ; ExitBootServices
        test rax, rax
        jnz .retry
        cli
        mov rax, [tramp]
        jmp rax
    
    fail_range:
        lea rdx, [msg_range]
        jmp fail_msg
    fail_kbuf:
        lea rdx, [msg_kbuf]
        jmp fail_msg
    fail_low:
        lea rdx, [msg_low]
        jmp fail_msg
    fail_alloc:
        lea rdx, [msg_kbuf]
        jmp fail_msg
    fail_file:
        lea rdx, [msg_file]
        jmp fail_msg
    fail_mm:
        lea rdx, [msg_mm]
    fail_msg:
        call puts
        mov rax, 0x8000000000000001
        add rsp, 56
        ret
    
    puthex:                             ; rax -> 16 hex digits + CRLF
        sub rsp, 56
        lea rdx, [hexbuf]
        mov ecx, 16
    .d:
        rol rax, 4
        mov r8d, eax
        and r8d, 15
        lea r9, [hexdigits]
        movzx r8d, byte [r9 + r8]
        mov [rdx], r8w
        add rdx, 2
        dec ecx
        jnz .d
        lea rdx, [hexbuf]
        call puts
        add rsp, 56
        ret
    hexdigits: db "0123456789abcdef"
    hexbuf: times 16 dw 0
        dw 13, 10, 0
    
    puts:                               ; rdx = UTF-16 string
        sub rsp, 56
        mov rax, [systab]
        mov rcx, [rax + 64]
        call [rcx + 8]
        add rsp, 56
        ret
    
    align 8
    image: dq 0
    systab: dq 0
    bs: dq 0
    gop: dq 0
    modesz: dq 0
    modeinfo: dq 0
    fb_addr: dq 0
    taddr: dq 0
    kbuf: dq 0
    loaded: dq 0
    sfs: dq 0
    root: dq 0
    kfile: dq 0
    ksize_v: dq 0
    mbi: dq 0
    mbi_cur: dq 0
    tramp: dq 0
    mmbuf: dq 0
    mmsize: dq 0
    mmkey: dq 0
    mmcount: dq 0
    descsz: dq 0
    descver: dq 0
    fb_pitch: dd 0
    fb_fmt: dd 0
    have_fb: db 0
    have_rsdp: db 0
    align 8
    guid_gop: dd 0x9042a9de
        dw 0x23dc, 0x4a38
        db 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a
    guid_loaded: dd 0x5b1b31a1
        dw 0x9562, 0x11d2
        db 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b
    guid_sfs: dd 0x964e5b22
        dw 0x6459, 0x11d2
        db 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b
    guid_acpi: dd 0x8868e871
        dw 0xe4f1, 0x11d3
        db 0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81
    kname: """ .. u16s("\\SPRINTOS.BIN") .. """
    msg_banner: """ .. u16s("Sprint OS UEFI loader (Sprint)\r\n") .. """
    msg_range: """ .. u16s("Sprint loader: the kernel's address range is not free memory\r\n") .. """
    msg_kbuf: """ .. u16s("Sprint loader: cannot allocate the file buffer\r\n") .. """
    msg_low: """ .. u16s("Sprint loader: cannot allocate low memory\r\n") .. """
    msg_file: """ .. u16s("Sprint loader: cannot read SPRINTOS.BIN\r\n") .. """
    msg_mm: """ .. u16s("Sprint loader: GetMemoryMap failed\r\n") .. """
    cmdline: """ .. db_string(cmdline) .. """
    align 8
    ktable:
    """ .. ktable .. """
    rsdp_buf: times 36 db 0
    align 8
    tramp_blob:
    """
    # the trampoline's bytes follow the label as data
    let blob = ""
    let parts = []
    for b in tramp.bytes:
        parts.append(to_string(b))
        if len(parts) == 16:
            blob = blob .. "db " .. parts.join(", ") .. "\n"
            parts = []
    if len(parts) > 0:
        blob = blob .. "db " .. parts.join(", ") .. "\n"
    let app = asm.assemble(app_src .. blob, {bits: 64, org: 0})
    let efi = uefi_pe.build(app.bytes, 0)
    return {efi: efi, kbin: kbin, kbin_size: kbin_size, nsegs: len(segs)}
