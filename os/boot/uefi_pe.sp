# uefi_pe: a PE32+ (EFI application) writer. One .text section holds code and data; the code must be position independent
# (RIP-relative addressing). A minimal base-relocation directory is included so the firmware's loader treats the image as relocatable.
#
#   let image = uefi_pe.build(code_bytes, entry_offset)      # array of bytes (0..255), x86-64, subsystem EFI application

func u16(v):
    return [v & 255, (v >> 8) & 255]

func u32(v):
    return [v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]

func cat(...parts):
    let out = []
    for p in parts:
        for b in p:
            out.append(b)
    return out

func le64(v):
    return cat(u32(v & 0xffffffff), u32((v >> 32) & 0xffffffff))

func align(v, a):
    return (v + a - 1) // a * a

const SECTION_ALIGN = 0x1000
const FILE_ALIGN = 0x200
const HEADERS = 0x200
const IMAGE_BASE = 0x140000000

export func build(code, entry):
    # the base-relocation directory: one block for the page at RVA 0x1000 with no entries (8 bytes)
    let reloc_off = align(len(code), 8)
    let body = []
    for b in code:
        body.append(b)
    while len(body) < reloc_off:
        body.append(0)
    let reloc_rva = SECTION_ALIGN + len(body)
    for b in cat(u32(SECTION_ALIGN), u32(8)):
        body.append(b)
    let vsize = len(body)
    let raw = align(vsize, FILE_ALIGN)
    while len(body) < raw:
        body.append(0)
    let size_of_image = SECTION_ALIGN + align(vsize, SECTION_ALIGN)

    let h = []
    # DOS header: "MZ", e_lfanew = 0x40
    h = cat(h, [0x4d, 0x5a])
    while len(h) < 0x3c:
        h.append(0)
    h = cat(h, u32(0x40))
    # PE signature and COFF header
    h = cat(h, [0x50, 0x45, 0, 0], u16(0x8664), u16(1), u32(0), u32(0), u32(0), u16(240), u16(0x0022))
    # optional header (PE32+)
    h = cat(h, u16(0x020b), [0, 0], u32(raw), u32(0), u32(0), u32(SECTION_ALIGN + entry), u32(SECTION_ALIGN))
    h = cat(h, le64(IMAGE_BASE), u32(SECTION_ALIGN), u32(FILE_ALIGN), u16(0), u16(0), u16(0), u16(0), u16(0), u16(0), u32(0))
    h = cat(h, u32(size_of_image), u32(HEADERS), u32(0), u16(10), u16(0))
    h = cat(h, le64(0x100000), le64(0x1000), le64(0x100000), le64(0x1000), u32(0), u32(16))
    for i in range(16):
        if i == 5:
            h = cat(h, u32(reloc_rva), u32(8))
        else:
            h = cat(h, u32(0), u32(0))
    # the section table: .text, readable / writable / executable code
    h = cat(h, [0x2e, 0x74, 0x65, 0x78, 0x74, 0, 0, 0], u32(vsize), u32(SECTION_ALIGN), u32(raw), u32(HEADERS), u32(0), u32(0), u16(0), u16(0), u32(0xe0000060))
    while len(h) < HEADERS:
        h.append(0)
    return cat(h, body)
