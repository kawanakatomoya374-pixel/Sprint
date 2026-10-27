# kelf: the ELF64 loader. Maps the PT_LOAD segments of a static (PIE or fixed) executable into a vmm.Space,
# reading the image straight from physical memory, and returns the entry point and program-header facts.
import hw
import vmm

func u16(a):
    return hw.peek16(a)

export class Image:
    let entry = 0
    let base = 0
    let phdr = 0
    let phnum = 0
    let phent = 0
    let top = 0
    let ok = false
    let why = ""

# load the image at physical `src` (length n) into `space`; PIE images are placed at `base`
export func load(space, src, n, base):
    let im = Image()
    if n < 64 or hw.peek32(src) != 0x464C457F:
        im.why = "not an ELF image"
        return im
    if hw.peek8(src + 4) != 2 or u16(src + 18) != 62:
        im.why = "not an x86-64 ELF64 image"
        return im
    let typ = u16(src + 16)
    let bias = base if typ == 3 else 0
    let phoff = hw.peek64(src + 32)
    im.phent = u16(src + 54)
    im.phnum = u16(src + 56)
    im.entry = hw.peek64(src + 24) + bias
    im.base = bias
    let top = 0
    let first = true
    for i in range(im.phnum):
        let ph = src + phoff + i * im.phent
        let kind = hw.peek32(ph)
        if kind == 6:   # PT_PHDR
            im.phdr = hw.peek64(ph + 16) + bias
        if kind != 1:   # PT_LOAD
            continue
        let off = hw.peek64(ph + 8)
        let va = hw.peek64(ph + 16) + bias
        let filesz = hw.peek64(ph + 32)
        let memsz = hw.peek64(ph + 40)
        if off + filesz > n:
            im.why = "segment outside the image"
            return im
        space.map_range(va, memsz + (va & 4095), vmm.W | vmm.U)
        # copy page by page into the freshly zeroed frames
        let done = 0
        while done < filesz:
            let p = space.translate(va + done)
            let chunk = 4096 - ((va + done) & 4095)
            if chunk > filesz - done:
                chunk = filesz - done
            hw.memcpy(p, src + off + done, chunk)
            done += chunk
        if va + memsz > top:
            top = va + memsz
        if first and im.phdr == 0 and off == 0:
            im.phdr = va + phoff
        first = false
    im.top = (top + 4095) & ~4095
    im.ok = true
    return im
