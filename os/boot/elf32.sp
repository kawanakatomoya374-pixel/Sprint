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
