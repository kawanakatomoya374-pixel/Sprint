# elf32: the loadable segments of a 32-bit ELF kernel (what the boot loaders copy into memory).
#
#   let info = elf32.parse(bytes_of_the_file, "name")      # {entry, segs: [{off, paddr, filesz, memsz}]}
export func parse(elf, name):
    func u32(off):
        return elf[off] | (elf[off + 1] << 8) | (elf[off + 2] << 16) | (elf[off + 3] << 24)
    func u16(off):
        return elf[off] | (elf[off + 1] << 8)
    if len(elf) < 64 or elf[0] != 0x7f or elf[1] != 0x45 or elf[4] != 1:
        throw error("ValueError", name .. " is not a 32-bit ELF file (objcopy -O elf32-i386)")
    let phoff = u32(28)
    let phentsize = u16(42)
    let phnum = u16(44)
    let segs = []
    for i in range(phnum):
        let ph = phoff + i * phentsize
        if u32(ph) == 1:   # PT_LOAD
            segs.append({off: u32(ph + 4), paddr: u32(ph + 12), filesz: u32(ph + 16), memsz: u32(ph + 20)})
    return {entry: u32(24), segs: segs}

# The relocations of a kernel linked with --emit-relocs (a 64-bit ELF): one entry per location that holds an address of the image, so that a
# loader can move the image by adding the displacement to each. Entry = (offset from link_base) | 0x80000000 for an 8-byte slot (4 bytes otherwise).
# Only allocated sections count; PC-relative, TLS and absolute-symbol relocations need no change.
export func relocs(elf, link_base):
    func u16(o):
        return elf[o] | (elf[o + 1] << 8)
    func u32(o):
        return elf[o] | (elf[o + 1] << 8) | (elf[o + 2] << 16) | (elf[o + 3] << 24)
    func u64(o):
        return u32(o) | (u32(o + 4) << 32)
    if len(elf) < 64 or elf[0] != 0x7f or elf[1] != 0x45 or elf[4] != 2:
        throw error("ValueError", "relocs() needs the 64-bit kernel.elf linked with -Wl,-q")
    let shoff = u64(40)
    let shentsize = u16(58)
    let shnum = u16(60)
    let out = []
    for i in range(shnum):
        let h = shoff + i * shentsize
        if u32(h + 4) != 4:          # SHT_RELA
            continue
        let th = shoff + u32(h + 44) * shentsize
        if (u64(th + 8) & 2) == 0:   # the relocated section is not SHF_ALLOC (debug information)
            continue
        let symtab = u64(shoff + u32(h + 40) * shentsize + 24)
        let e = u64(h + 24)
        let end = e + u64(h + 32)
        while e < end:
            let info = u64(e + 8)
            let kind = info & 0xffffffff
            let sym = info >> 32
            let wide = kind == 1
            if sym != 0 and (wide or kind == 10 or kind == 11) and u16(symtab + sym * 24 + 6) != 0xfff1:
                out.append((u64(e) - link_base) | (0x80000000 if wide else 0))
            e += 24
    return out
