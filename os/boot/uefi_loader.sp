# uefi_loader: the Sprint OS UEFI loader and kernel file (see uefiboot.sp for the description), as a module so that the plain UEFI
# image and the hybrid BIOS + UEFI image share it.
#
#   let u = uefi_loader.build(elf_bytes, info, "init=boot", kernel_elf64_bytes)
#   u.efi      \EFI\BOOT\BOOTX64.EFI (a PE32+ file)
#   u.kbin     \SPRINTOS.BIN: the kernel's PT_LOAD segments, concatenated, then the relocation table (u32 entries, see elf32.relocs)
#
# The kernel is relocatable: the loader asks the firmware for a free block anywhere below 4 GiB, copies the segments there and adds the
# displacement to every address the kernel holds (the table comes from the 64-bit kernel.elf, linked with -Wl,-q).
import asm
import boot_menu
import elf32
import hash
import sha256_asm
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


func dd_words(ws):
    let parts = []
    for w in ws:
        parts.append(to_string(w))
    return "dd " .. parts.join(", ")

export func build(elf, info, cmdline, elf64):
    let menu = boot_menu.parse(cmdline)
    let entry = info.entry
    let segs = []
    let seg_bytes = 0
    let minp = info.segs[0].paddr
    let maxend = 0
    for i in range(len(info.segs)):
        let t = info.segs[i]
        segs.append({off: t.off, paddr: t.paddr, filesz: t.filesz, memsz: t.memsz, fileoff: seg_bytes})
        seg_bytes += t.filesz
        if t.paddr < minp:
            minp = t.paddr
        if t.paddr + t.memsz > maxend:
            maxend = t.paddr + t.memsz
    let rel = elf32.relocs(elf64, minp)
    let kbin_size = seg_bytes + 4 * len(rel)
    let kimg_pages = (maxend - minp + 4095) // 4096
    let kbin = typed.u8(kbin_size)
    for s in segs:
        for i in range(s.filesz):
            kbin[s.fileoff + i] = elf[s.off + i]
    for k in range(len(rel)):
        for j in range(4):
            kbin[seg_bytes + 4 * k + j] = (rel[k] >> (8 * j)) & 255
    let ktable = ""
    for s in segs:
        ktable = ktable .. "    dd " .. to_string(s.fileoff) .. ", " .. to_string(s.paddr - minp) .. ", " .. to_string(s.filesz) .. ", " .. to_string(s.memsz) .. "\n"
    
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
        ; the kernel's segments: copy from the file buffer to base + their offset, zero the bss (no page tables to protect any more)
        lea ebx, [ebp + t_ktable]
        mov eax, [ebp + t_nseg]
        mov [ebp + t_cnt], eax
    .cs:
        mov esi, [ebx]
        add esi, [ebp + t_kbuf]
        mov edi, [ebx + 4]
        add edi, [ebp + t_base]
        mov ecx, [ebx + 8]
        cld
        rep movsb
        mov edi, [ebx + 4]
        add edi, [ebx + 8]
        add edi, [ebp + t_base]
        mov ecx, [ebx + 12]
        sub ecx, [ebx + 8]
        xor eax, eax
        rep stosb
        add ebx, 16
        dec dword [ebp + t_cnt]
        jnz .cs
        ; relocation: every slot that holds an address of the image moves by the displacement (new base - link base)
        mov ebx, [ebp + t_kbuf]
        add ebx, [ebp + t_reloff]
        mov ecx, [ebp + t_relcnt]
        mov edx, [ebp + t_delta]
        mov esi, [ebp + t_base]
    .rl:
        test ecx, ecx
        jz .rld
        mov eax, [ebx]
        mov edi, eax
        and edi, 0x7fffffff
        add edi, esi
        test eax, 0x80000000
        jnz .w8
        add [edi], edx
        jmp .rn
    .w8:
        add [edi], edx
        adc dword [edi + 4], 0
    .rn:
        add ebx, 4
        dec ecx
        jmp .rl
    .rld:
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
    t_base: dd 0
    t_delta: dd 0
    t_reloff: dd """ .. to_string(seg_bytes) .. """
    t_relcnt: dd """ .. to_string(len(rel)) .. """
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

        ; ---- Secure Boot lockdown: with Secure Boot on, the command line cannot be edited ----
        mov qword [varsize], 1
        lea rcx, [wname_secureboot]
        lea rdx, [guid_global]
        xor r8d, r8d
        lea r9, [varsize]
        lea rax, [vardata]
        mov [rsp + 32], rax
        mov rax, [systab]
        mov rax, [rax + 88]             ; RuntimeServices
        call [rax + 72]                 ; GetVariable
        test rax, rax
        jnz .nosb
        cmp byte [vardata], 1
        jne .nosb
        mov byte [locked], 1
    .nosb:

        ; ---- the boot menu (or the one fixed command line) ----
        lea rax, [menu_cmd""" .. to_string(menu.default) .. """]
        mov [cmdptr], rax
        cmp byte [menu_on], 0
        je .nomenu
        call run_menu
    .nomenu:
    
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
        mov qword [kbase], 0xffffffff   ; the relocated kernel: any free block below 4 GiB (the identity map the kernel builds covers it)
        mov ecx, 1
        mov edx, 2
        mov r8d, """ .. to_string(kimg_pages) .. """
        lea r9, [kbase]
        mov rax, [bs]
        call [rax + 40]
        test rax, rax
        jnz fail_kbuf
        cmp qword [kbase], """ .. to_string(minp) .. """   ; relocation adds a non-negative displacement
        jb fail_range
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
        ; ---- the kernel file must be the one this loader was built with (the hash is inside this -- signed -- image) ----
        lea rdi, [shactx]
        mov rsi, [kbuf]
        mov rdx, """ .. to_string(kbin_size) .. """
        call sha256_all
        lea rsi, [shactx]
        lea rdi, [khash]
        mov ecx, 8
        cld
        repe cmpsd
        jne fail_hash
    
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
        mov eax, [kbase]
        mov [rdi + """ .. to_string(TL["t_base"]) .. """], eax
        sub eax, """ .. to_string(minp) .. """
        mov [rdi + """ .. to_string(TL["t_delta"]) .. """], eax
        mov eax, [kbase]
        add eax, """ .. to_string(entry - minp) .. """
        mov [rdi + """ .. to_string(TL["t_entry"]) .. """], eax
        mov eax, [kbuf]
        mov [rdi + """ .. to_string(TL["t_kbuf"]) .. """], eax
        lea rax, [rdi + """ .. to_string(TL["t_gdt"]) .. """]
        mov [rdi + """ .. to_string(TL["t_gdtptr"] + 2) .. """], rax
    
        ; ---- the Multiboot2 information structure: command line, framebuffer, RSDP; the memory map goes last ----
        mov rdi, [mbi]
        mov dword [rdi], 0
        mov dword [rdi + 4], 0
        add rdi, 8
        mov dword [rdi], 1              ; command line (the chosen entry or the edited text)
        mov rsi, [cmdptr]
        mov rcx, rsi
    .cl:
        cmp byte [rcx], 0
        je .cle
        inc rcx
        jmp .cl
    .cle:
        sub rcx, rsi
        lea eax, [rcx + 9]              ; tag size = 8 + length + 1
        mov [rdi + 4], eax
        mov r10, rdi
        add rdi, 8
        inc ecx
        cld
        rep movsb
        mov rdi, r10
        mov eax, [r10 + 4]
        add eax, 7
        and eax, 0xfffffff8
        add rdi, rax
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
    fail_hash:
        lea rdx, [msg_hash]
        jmp fail_msg
    fail_mm:
        lea rdx, [msg_mm]
    fail_msg:
        call puts
        mov rax, 0x8000000000000001
        add rsp, 56
        ret
    

    putc16:                             ; ecx = character
        sub rsp, 56
        mov [chbuf], cx
        mov word [chbuf + 2], 0
        lea rdx, [chbuf]
        call puts
        add rsp, 56
        ret

    putnum:                             ; eax (0..99) in decimal
        sub rsp, 56
        xor edx, edx
        mov ecx, 10
        div ecx
        mov [numtmp], edx
        test eax, eax
        jz .u
        lea ecx, [rax + 48]
        call putc16
    .u: mov ecx, [numtmp]
        add ecx, 48
        call putc16
        add rsp, 56
        ret

    getkey:                             ; eax = (scan code << 16) | character, 0 when no key is waiting
        sub rsp, 56
        mov rax, [systab]
        mov rcx, [rax + 48]             ; ConIn
        lea rdx, [keybuf]
        call [rcx + 8]                  ; ReadKeyStroke
        test rax, rax
        jnz .none
        movzx eax, word [keybuf]
        shl eax, 16
        movzx ecx, word [keybuf + 2]
        or eax, ecx
        add rsp, 56
        ret
    .none:
        xor eax, eax
        add rsp, 56
        ret

    sleep100:
        sub rsp, 56
        mov rax, [bs]
        mov ecx, 100000
        call [rax + 248]                ; Stall (microseconds)
        add rsp, 56
        ret

    clear_screen:
        sub rsp, 56
        mov rax, [systab]
        mov rcx, [rax + 64]
        call [rcx + 48]                 ; ConOut->ClearScreen
        add rsp, 56
        ret

    print_edit:                         ; the edit buffer (ASCII) as UTF-16
        lea rsi, [editbuf]
        lea rdi, [abuf]
    .c: movzx eax, byte [rsi]
        mov [rdi], ax
        test eax, eax
        jz .d
        inc rsi
        add rdi, 2
        jmp .c
    .d: lea rdx, [abuf]
        jmp puts

    draw_menu:
        push rbx
        push rsi
        push rdi
        push r12
        sub rsp, 56
        call clear_screen
        lea rdx, [wmsg_title]
        call puts
        xor ebx, ebx
    .e: movzx eax, word [menu_count]
        cmp ebx, eax
        jae .done
        mov ecx, 32
        cmp ebx, [sel]
        jne .n
        mov ecx, 62
    .n: call putc16
        mov ecx, 32
        call putc16
        lea ecx, [rbx + 49]
        call putc16
        mov ecx, 46
        call putc16
        mov ecx, 32
        call putc16
        lea rcx, [menu_tab]
        mov edx, [rcx + rbx * 8]
        add rdx, rcx
        call puts
        lea rdx, [wmsg_crlf]
        call puts
        inc ebx
        jmp .e
    .done:
        lea rdx, [wmsg_help]
        call puts
        cmp byte [locked], 0
        je .nolock
        lea rdx, [wmsg_locked]
        call puts
    .nolock:
        cmp byte [counting], 0
        je .r
        lea rdx, [wmsg_count1]
        call puts
        mov eax, [ticks]
        add eax, 9
        xor edx, edx
        mov ecx, 10
        div ecx
        call putnum
        lea rdx, [wmsg_count2]
        call puts
    .r: add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret

    run_menu:
        push rbx
        push rsi
        push rdi
        push r12
        sub rsp, 56
        movzx eax, word [menu_default]
        mov [sel], eax
        mov byte [counting], 0
        movzx eax, word [menu_timeout]
        test eax, eax
        jz .redraw
        imul eax, eax, 10
        mov [ticks], eax
        mov byte [counting], 1
    .redraw:
        call draw_menu
    .poll:
        call getkey
        test eax, eax
        jnz .key
        call sleep100
        cmp byte [counting], 0
        je .poll
        dec dword [ticks]
        jz .boot
        mov eax, [ticks]
        xor edx, edx
        mov ecx, 10
        div ecx
        test edx, edx
        jnz .poll
        jmp .redraw
    .key:
        mov byte [counting], 0
        mov edx, eax
        shr edx, 16
        movzx eax, ax
        cmp edx, 1                      ; up
        je .up
        cmp edx, 2                      ; down
        je .down
        cmp eax, 107                    ; 'k' / 'j'
        je .up
        cmp eax, 106
        je .down
        cmp eax, 13
        je .boot
        cmp eax, 10
        je .boot
        cmp eax, 101                    ; 'e'
        je .edit
        cmp eax, 69
        je .edit
        cmp eax, 49
        jb .redraw
        cmp eax, 57
        ja .redraw
        sub eax, 49
        movzx ecx, word [menu_count]
        cmp eax, ecx
        jae .redraw
        mov [sel], eax
        jmp .boot
    .up:
        mov eax, [sel]
        test eax, eax
        jz .redraw
        dec eax
        mov [sel], eax
        jmp .redraw
    .down:
        mov eax, [sel]
        inc eax
        movzx ecx, word [menu_count]
        cmp eax, ecx
        jae .redraw
        mov [sel], eax
        jmp .redraw
    .edit:
        cmp byte [locked], 0
        jne .redraw
        call edit_cmdline
        jc .redraw
        jmp .out
    .boot:
        mov eax, [sel]
        lea rcx, [menu_tab]
        mov edx, [rcx + rax * 8 + 4]
        add rcx, rdx
        mov [cmdptr], rcx
    .out:
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        ret

    edit_cmdline:                       ; CF set: cancelled; clear: cmdptr -> the edited text
        push rbx
        push rsi
        push rdi
        push r12
        sub rsp, 56
        mov eax, [sel]
        lea rcx, [menu_tab]
        mov edx, [rcx + rax * 8 + 4]
        lea rsi, [rcx + rdx]
        lea rdi, [editbuf]
        xor ebx, ebx
    .cp:
        mov al, [rsi]
        test al, al
        jz .cpd
        cmp ebx, 127
        jae .cpd
        mov [rdi + rbx], al
        inc rsi
        inc ebx
        jmp .cp
    .cpd:
        mov byte [rdi + rbx], 0
        mov [editlen], ebx
        lea rdx, [wmsg_edit]
        call puts
        call print_edit
    .k: call getkey
        test eax, eax
        jnz .got
        call sleep100
        jmp .k
    .got:
        mov edx, eax
        shr edx, 16
        movzx eax, ax
        cmp edx, 0x17                   ; Escape
        je .cancel
        cmp eax, 27
        je .cancel
        cmp eax, 13
        je .accept
        cmp eax, 10
        je .accept
        cmp eax, 8
        je .bs
        cmp eax, 127
        je .bs
        cmp eax, 32
        jb .k
        cmp eax, 126
        ja .k
        mov ebx, [editlen]
        cmp ebx, 127
        jae .k
        lea rdi, [editbuf]
        mov [rdi + rbx], al
        mov byte [rdi + rbx + 1], 0
        inc dword [editlen]
        mov ecx, eax
        call putc16
        jmp .k
    .bs:
        mov ebx, [editlen]
        test ebx, ebx
        jz .k
        dec ebx
        mov [editlen], ebx
        lea rdi, [editbuf]
        mov byte [rdi + rbx], 0
        mov ecx, 8
        call putc16
        mov ecx, 32
        call putc16
        mov ecx, 8
        call putc16
        jmp .k
    .accept:
        lea rax, [editbuf]
        mov [cmdptr], rax
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        clc
        ret
    .cancel:
        add rsp, 56
        pop r12
        pop rdi
        pop rsi
        pop rbx
        stc
        ret

    puts:                               ; rdx = UTF-16 string
        sub rsp, 56
        mov rax, [systab]
        mov rcx, [rax + 64]
        call [rcx + 8]
        add rsp, 56
        ret
    
    """ .. sha256_asm.text() .. """
    align 8
    shactx: times """ .. to_string(sha256_asm.CTX_SIZE) .. """ db 0
    khash: """ .. dd_words(sha256_asm.words(hash.sha256(kbin))) .. """
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
    kbase: dq 0
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
    msg_range: """ .. u16s("Sprint loader: no usable block for the kernel\r\n") .. """
    msg_kbuf: """ .. u16s("Sprint loader: cannot allocate the file buffer\r\n") .. """
    msg_low: """ .. u16s("Sprint loader: cannot allocate low memory\r\n") .. """
    msg_file: """ .. u16s("Sprint loader: cannot read SPRINTOS.BIN\r\n") .. """
    msg_hash: """ .. u16s("Sprint loader: SPRINTOS.BIN does not match the hash this loader was built with - refusing to boot\r\n") .. """
    msg_mm: """ .. u16s("Sprint loader: GetMemoryMap failed\r\n") .. """
    wname_secureboot: """ .. u16s("SecureBoot") .. """
    wmsg_title: """ .. u16s("Sprint OS boot menu\r\n\r\n") .. """
    wmsg_help: """ .. u16s("\r\n  Up/Down or 1-9: select   Enter: boot   e: edit the command line\r\n") .. """
    wmsg_locked: """ .. u16s("  (Secure Boot is on: the command line cannot be edited)\r\n") .. """
    wmsg_count1: """ .. u16s("\r\n  Booting the selected entry in ") .. """
    wmsg_count2: """ .. u16s(" s (any key stops the countdown)\r\n") .. """
    wmsg_edit: """ .. u16s("\r\n  command line (Enter: boot, Esc: back): ") .. """
    wmsg_crlf: """ .. u16s("\r\n") .. """
    guid_global: db 0x61, 0xdf, 0xe4, 0x8b, 0xca, 0x93, 0xd2, 0x11, 0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c
    cmdptr: dq 0
    varsize: dq 0
    vardata: dq 0
    locked: db 0
    counting: db 0
    align 4
    sel: dd 0
    ticks: dd 0
    editlen: dd 0
    numtmp: dd 0
    keybuf: dd 0
    chbuf: dd 0
    editbuf: times 132 db 0
    abuf: times 270 db 0
    """ .. boot_menu.data(menu, true) .. """
    align 8
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
