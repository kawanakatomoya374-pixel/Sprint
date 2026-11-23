# bios_loader: the Sprint OS BIOS bootloader (see sprintboot.sp for the description), as a module so that the plain BIOS image and
# the hybrid BIOS + UEFI image share it.
#
#   let b = bios_loader.build(elf_bytes, info, "init=boot", lba0)     # a command line, or a menu spec (see boot_menu.sp)
#   b.stage1      machine code for the MBR (<= 446 bytes, no partition table, no signature); reads stage 2 from LBA lba0
#   b.blob        stage 2 padded to STAGE2_SECTORS sectors, then every kernel segment on a sector boundary (this goes to LBA lba0..)
#   b.sectors     the size of the blob in sectors
import asm
import boot_menu
import typed

export const STAGE2_SECTORS = 8

func db_string(s):
    let parts = []
    for i in range(len(s)):
        parts.append(to_string(s[i]))
    return "db " .. parts.join(", ") .. ", 0"

export func build(elf, info, cmdline, lba0):
    let menu = boot_menu.parse(cmdline)
    let entry = info.entry
    let segs = []
    for s in info.segs:
        segs.append({off: s.off, paddr: s.paddr, filesz: s.filesz, memsz: s.memsz})
    # layout from lba0: stage 2 (STAGE2_SECTORS sectors), then every segment on a sector boundary
    let next_lba = lba0 + STAGE2_SECTORS
    let table = ""
    for s in segs:
        s.lba = next_lba
        next_lba += (s.filesz + 511) // 512
        table = table .. "    dd " .. to_string(s.lba) .. ", " .. to_string(s.paddr) .. ", " .. to_string(s.filesz) .. ", " .. to_string(s.memsz) .. "\n"
    
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
        dq """ .. to_string(lba0) .. """
    msg: db "stage 2: disk error", 0
    """
    
    # ---- stage 2 ----------------------------------------------------------------------------------------
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
        cmp byte [menu_on], 0
        je .nomenu
        call run_menu
    .nomenu:
    
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
        mov dword [es:di], 1            ; command line (the chosen entry or the edited text)
        mov si, [cmdptr]
        mov bx, si
    .cl:
        cmp byte [bx], 0
        je .cle
        inc bx
        jmp .cl
    .cle:
        sub bx, si                      ; length
        lea ax, [bx + 9]
        mov dx, ax                      ; tag size = 8 + length + 1
        movzx eax, ax
        mov [es:di + 4], eax
        mov cx, bx
        inc cx
        push di
        add di, 8
    .cpcmd:
        mov al, [si]
        mov [es:di], al
        inc si
        inc di
        loop .cpcmd
        pop di
        mov ax, dx
        add ax, 7
        and ax, 0xfff8
        add di, ax
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
        puts:                               ; si -> zero-terminated string, to the screen and COM1
            lodsb
            test al, al
            jz .d
            call putc
            jmp puts
        .d: ret

        putc:                               ; al -> the screen (BIOS teletype) and COM1; every register is kept
            pusha
            mov ah, 0x0e
            xor bx, bx
            int 0x10
            popa
            pusha
            mov bl, al
            mov dx, 0x3fd
            mov cx, 30000
        .w: in al, dx
            test al, 0x20
            jnz .s
            loop .w
        .s: mov dx, 0x3f8
            mov al, bl
            out dx, al
            popa
            ret

        getkey:                             ; ax = key (ah = scan code, al = ASCII) from the keyboard or COM1; 0 when there is none
            mov ah, 1
            int 0x16
            jz .serial
            xor ah, ah
            int 0x16
            ret
        .serial:
            mov dx, 0x3fd
            in al, dx
            test al, 1
            jz .none
            mov dx, 0x3f8
            in al, dx
            xor ah, ah
            ret
        .none:
            xor ax, ax
            ret

        sleep100:                           ; 100 ms
            pusha
            mov ah, 0x86
            mov cx, 1
            mov dx, 0x86a0
            int 0x15
            popa
            ret

        putnum:                             ; ax (0..99) in decimal
            pusha
            xor dx, dx
            mov bx, 10
            div bx
            test ax, ax
            jz .u
            add al, 48
            call putc
        .u: mov al, dl
            add al, 48
            call putc
            popa
            ret

        draw_menu:
            mov ax, 3                       ; 80x25 text mode (clears the screen)
            int 0x10
            mov si, msg_menu_title
            call puts
            xor cx, cx
        .e: cmp cx, [menu_count]
            jae .done
            mov al, 32
            cmp cx, [sel]
            jne .n
            mov al, 62
        .n: call putc
            mov al, 32
            call putc
            mov al, cl
            add al, 49
            call putc
            mov al, 46
            call putc
            mov al, 32
            call putc
            mov bx, cx
            shl bx, 2
            mov si, [menu_tab + bx]
            call puts
            mov si, msg_crlf
            call puts
            inc cx
            jmp .e
        .done:
            mov si, msg_menu_help
            call puts
            cmp byte [counting], 0
            je .r
            mov si, msg_countdown
            call puts
            mov ax, [ticks]
            add ax, 9
            xor dx, dx
            mov bx, 10
            div bx
            call putnum
            mov si, msg_countdown2
            call puts
        .r: ret

        run_menu:
            mov ax, [menu_default]
            mov [sel], ax
            mov byte [counting], 0
            mov ax, [menu_timeout]
            test ax, ax
            jz .redraw
            mov bx, 10
            mul bx
            mov [ticks], ax
            mov byte [counting], 1
        .redraw:
            call draw_menu
        .poll:
            call getkey
            test ax, ax
            jnz .key
            call sleep100
            cmp byte [counting], 0
            je .poll
            dec word [ticks]
            jz .boot
            mov ax, [ticks]
            xor dx, dx
            mov bx, 10
            div bx
            test dx, dx
            jnz .poll
            jmp .redraw
        .key:
            mov byte [counting], 0
            cmp ah, 0x48
            je .up
            cmp ah, 0x50
            je .down
            cmp al, 107                     ; 'k' / 'j' for terminals
            je .up
            cmp al, 106
            je .down
            cmp al, 13
            je .boot
            cmp al, 10
            je .boot
            cmp al, 101                     ; 'e'
            je .edit
            cmp al, 69
            je .edit
            cmp al, 49
            jb .redraw
            cmp al, 57
            ja .redraw
            sub al, 49
            xor ah, ah
            cmp ax, [menu_count]
            jae .redraw
            mov [sel], ax
            jmp .boot
        .up:
            mov ax, [sel]
            test ax, ax
            jz .redraw
            dec ax
            mov [sel], ax
            jmp .redraw
        .down:
            mov ax, [sel]
            inc ax
            cmp ax, [menu_count]
            jae .redraw
            mov [sel], ax
            jmp .redraw
        .edit:
            call edit_cmdline
            jc .redraw
            ret
        .boot:
            mov bx, [sel]
            shl bx, 2
            mov ax, [menu_tab + bx + 2]
            mov [cmdptr], ax
            ret

        edit_cmdline:                       ; CF set: cancelled; clear: cmdptr -> the edited text
            mov bx, [sel]
            shl bx, 2
            mov si, [menu_tab + bx + 2]
            mov di, editbuf
            xor cx, cx
        .cp:
            lodsb
            test al, al
            jz .cpd
            cmp cx, 127
            jae .cpd
            mov [di], al
            inc di
            inc cx
            jmp .cp
        .cpd:
            mov byte [di], 0
            mov [editlen], cx
            mov si, msg_edit
            call puts
            mov si, editbuf
            call puts
        .k: call getkey
            test ax, ax
            jnz .got
            call sleep100
            jmp .k
        .got:
            cmp al, 27
            je .cancel
            cmp al, 13
            je .accept
            cmp al, 10
            je .accept
            cmp al, 8
            je .bs
            cmp al, 127
            je .bs
            cmp al, 32
            jb .k
            cmp al, 126
            ja .k
            mov cx, [editlen]
            cmp cx, 127
            jae .k
            mov bx, editbuf
            add bx, cx
            mov [bx], al
            mov byte [bx + 1], 0
            inc word [editlen]
            call putc
            jmp .k
        .bs:
            mov cx, [editlen]
            test cx, cx
            jz .k
            dec cx
            mov [editlen], cx
            mov bx, editbuf
            add bx, cx
            mov byte [bx], 0
            mov al, 8
            call putc
            mov al, 32
            call putc
            mov al, 8
            call putc
            jmp .k
        .accept:
            mov word [cmdptr], editbuf
            clc
            ret
        .cancel:
            stc
            ret

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
    msg_menu_title: """ .. db_string("Sprint OS boot menu\r\n\r\n") .. """
    msg_menu_help: """ .. db_string("\r\n  Up/Down or 1-9: select   Enter: boot   e: edit the command line\r\n") .. """
    msg_countdown: """ .. db_string("\r\n  Booting the selected entry in ") .. """
    msg_countdown2: """ .. db_string(" s (any key stops the countdown)\r\n") .. """
    msg_edit: """ .. db_string("\r\n  command line (Enter: boot, Esc: back): ") .. """
    msg_crlf: """ .. db_string("\r\n") .. """
    sel: dw 0
    ticks: dw 0
    counting: db 0
    editlen: dw 0
    editbuf: times 132 db 0
    """ .. boot_menu.data(menu, false) .. """
    align 4
    ktable:
    """ .. table .. """
    rsdp_buf: times 36 db 0
    """
    
    let s1 = asm.assemble(stage1, {bits: 16, org: 0x7c00})
    if len(s1.bytes) > 446:
        throw error("ValueError", "stage 1 is " .. to_string(len(s1.bytes)) .. " bytes; the MBR code area is 446")
    let s2 = asm.assemble(stage2, {bits: 16, org: 0x8000})
    if len(s2.bytes) > STAGE2_SECTORS * 512:
        throw error("ValueError", "stage 2 is " .. to_string(len(s2.bytes)) .. " bytes; raise STAGE2_SECTORS")
    let total = STAGE2_SECTORS * 512
    for s in segs:
        total += (s.filesz + 511) // 512 * 512
    let blob = typed.u8(total)
    for i in range(len(s2.bytes)):
        blob[i] = s2.bytes[i]
    let at = STAGE2_SECTORS * 512
    for s in segs:
        for i in range(s.filesz):
            blob[at + i] = elf[s.off + i]
        at += (s.filesz + 511) // 512 * 512
    return {stage1: s1.bytes, blob: blob, sectors: len(blob) // 512, stage2_bytes: len(s2.bytes)}
