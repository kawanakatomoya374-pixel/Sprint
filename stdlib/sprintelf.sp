# sprintelf: an ELF64 / x86-64 loader and dynamic linker written in Sprint.
# The design (what is checked, symbol scope order, RELR, IFUNC deferral, TLS variant II, dlopen / dlclose) follows the C-OS
# kernel loader (cos_elf.c, cos_elf_link.c); this is a clean Sprint implementation working on a simulated address space.
#
#   import sprintelf
#   let info = sprintelf.inspect(bytes)         # header, PT_* summary, DT_NEEDED / SONAME / RPATH / RUNPATH
#   let sp = sprintelf.Space()                  # an address space: regions of bytes at virtual addresses
#   let ln = sprintelf.Linker(sp, read_file)    # read_file(path) -> bytes or nil
#   let main = ln.load_executable("/bin/prog", bytes, base)    # maps, loads DT_NEEDED, relocates, builds the TLS block
#   let h = ln.dlopen("libx.so", sprintelf.RTLD_GLOBAL)       # -> handle or nil (ln.dlerror() says why)
#   ln.dlsym(h, "name")                         # address or nil;  ln.dlsym(sprintelf.RTLD_DEFAULT, "name")
#   ln.dlclose(h)
# Lower level: map_object(), lookup(), relocate(), tls_layout(), tls_init().
#
# Relocations: RELATIVE / RELR / 64 / GLOB_DAT / JUMP_SLOT / PC32 / PLT32 / 32 / 32S / COPY / SIZE / TLS (DTPMOD64, DTPOFF64, TPOFF64)
# and IRELATIVE (recorded in obj.ifuncs, the slot is left 0: running the resolvers is the process's own job). TLSDESC and the
# link-time-only types are refused. Symbols: DT_GNU_HASH, DT_HASH or a linear scan, with symbol versions.
import typed
import str

export const RTLD_LAZY = 1
export const RTLD_NOW = 2
export const RTLD_NOLOAD = 4
export const RTLD_DEEPBIND = 8
export const RTLD_GLOBAL = 0x100
export const RTLD_NODELETE = 0x1000
export const RTLD_DEFAULT = 0

const PT_LOAD = 1
const PT_DYNAMIC = 2
const PT_INTERP = 3
const PT_TLS = 7
const PT_GNU_STACK = 0x6474e551
const PT_GNU_RELRO = 0x6474e552
const PAGE = 4096
const MAX_LOAD = 16
const MAX_RELOCS = 4000000
const MAX_SEGMENT = 1 << 30

func fail(msg):
    throw error("ValueError", "sprintelf: " .. msg)

func page_down(v):
    return v & (~(PAGE - 1))

func page_up(v):
    return (v + PAGE - 1) & (~(PAGE - 1))

func align_up(v, a):
    return (v + a - 1) // a * a

func u16(d, o):
    return d[o] | (d[o + 1] << 8)

func u32(d, o):
    return d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24)

func u64(d, o):
    return u32(d, o) | (u32(d, o + 4) << 32)

func cstr_at(d, o, limit):
    let n = len(d)
    let i = o
    while i < n and i < o + limit and d[i] != 0:
        i += 1
    let b = typed.u8(i - o)
    for k in range(i - o):
        b[k] = d[o + k]
    return str.from_bytes(b)

func as_u8(d):
    if type(d) == "native":
        return d
    let r = typed.u8(len(d))
    for i in range(len(d)):
        r[i] = d[i]
    return r

# ---------------------------------------------------------------------------------------------------------------------
# the address space
# ---------------------------------------------------------------------------------------------------------------------
export func Space():
    let regions = []
    let last = nil

    func find(a, n):
        if last != nil and a >= last.start and a + n <= last.end:
            return last
        for r in regions:
            if a >= r.start and a + n <= r.end:
                last = r
                return r
        return nil

    func map(start, length):
        let s = page_down(start)
        let e = page_up(start + length)
        for r in regions:
            if s < r.end and r.start < e:
                fail("mapping 0x" .. hex(s) .. " overlaps an existing region")
        let r = {start: s, end: e, mem: typed.u8(e - s)}
        regions.append(r)
        return r

    func unmap(start, end):
        let keep = []
        for r in regions:
            if not (r.start >= start and r.end <= end):
                keep.append(r)
        regions = keep
        last = nil

    func mapped(a, n):
        return find(a, n) != nil

    func read_n(a, n):
        let r = find(a, n)
        if r == nil:
            fail("read outside mapped memory at 0x" .. hex(a))
        let o = a - r.start
        let v = 0
        let i = n - 1
        while i >= 0:
            v = (v << 8) | r.mem[o + i]
            i -= 1
        return v

    func write_n(a, n, v):
        let r = find(a, n)
        if r == nil:
            fail("write outside mapped memory at 0x" .. hex(a))
        let o = a - r.start
        for i in range(n):
            r.mem[o + i] = (v >> (8 * i)) & 255

    func read_bytes(a, n):
        let out = typed.u8(n)
        if n == 0:
            return out
        let r = find(a, n)
        if r == nil:
            fail("read outside mapped memory at 0x" .. hex(a))
        let o = a - r.start
        for i in range(n):
            out[i] = r.mem[o + i]
        return out

    func write_bytes(a, src, n):
        if n == 0:
            return nil
        let r = find(a, n)
        if r == nil:
            fail("write outside mapped memory at 0x" .. hex(a))
        let o = a - r.start
        for i in range(n):
            r.mem[o + i] = src[i]

    func cstr(a, limit):
        let r = find(a, 1)
        if r == nil:
            fail("read outside mapped memory at 0x" .. hex(a))
        let o = a - r.start
        let i = o
        while i < len(r.mem) and i < o + limit and r.mem[i] != 0:
            i += 1
        let b = typed.u8(i - o)
        for k in range(i - o):
            b[k] = r.mem[o + k]
        return str.from_bytes(b)

    func get_regions():
        return regions

    func r8(a):
        return read_n(a, 1)

    func r16(a):
        return read_n(a, 2)

    func r32(a):
        return read_n(a, 4)

    func r64(a):
        return read_n(a, 8)

    func w8(a, v):
        write_n(a, 1, v)

    func w16(a, v):
        write_n(a, 2, v)

    func w32(a, v):
        write_n(a, 4, v)

    func w64(a, v):
        write_n(a, 8, v)

    return {map: map, unmap: unmap, mapped: mapped, regions: get_regions, r8: r8, r16: r16, r32: r32, r64: r64, w8: w8, w16: w16, w32: w32, w64: w64, read_bytes: read_bytes, write_bytes: write_bytes, cstr: cstr}

func hex(v):
    let digits = "0123456789abcdef"
    if v == 0:
        return "0"
    let s = ""
    let n = 0
    while v != 0 and n < 16:
        s = digits.slice(v & 15, (v & 15) + 1) .. s
        v = (v >> 4) & 0x0fffffffffffffff
        n += 1
    return s

# ---------------------------------------------------------------------------------------------------------------------
# header, program headers, inspect
# ---------------------------------------------------------------------------------------------------------------------
func parse_header(d):
    let n = len(d)
    if n < 64:
        fail("file smaller than an ELF header")
    if d[0] != 0x7f or d[1] != 0x45 or d[2] != 0x4c or d[3] != 0x46:
        fail("not an ELF file (bad magic)")
    if d[4] != 2:
        fail("not ELF64")
    if d[5] != 1:
        fail("not little-endian")
    let h = {type: u16(d, 16), machine: u16(d, 18), entry: u64(d, 24), phoff: u64(d, 32), phentsize: u16(d, 54), phnum: u16(d, 56)}
    if h.machine != 62:
        fail("not x86-64")
    if h.type != 2 and h.type != 3:
        fail("not an executable or shared object (ET_EXEC / ET_DYN required)")
    if h.phnum == 0 or h.phnum > 64 or h.phentsize < 56 or h.phoff < 0 or h.phoff + h.phnum * h.phentsize > n:
        fail("bad program header table")
    let ph = []
    for i in range(h.phnum):
        let o = h.phoff + i * h.phentsize
        ph.append({type: u32(d, o), flags: u32(d, o + 4), offset: u64(d, o + 8), vaddr: u64(d, o + 16), filesz: u64(d, o + 32), memsz: u64(d, o + 40), align: u64(d, o + 48)})
    h.ph = ph
    return h

func validate_loads(h, n):
    let lo = nil
    let hi = 0
    let cnt = 0
    let loads = []
    for p in h.ph:
        if p.type != PT_LOAD:
            continue
        if p.filesz < 0 or p.memsz < p.filesz or p.memsz > MAX_SEGMENT or p.offset < 0 or p.offset + p.filesz > n or p.vaddr < 0 or p.vaddr + p.memsz < p.vaddr:
            fail("bad PT_LOAD segment (size, file range or address range)")
        if p.memsz == 0:
            continue
        cnt += 1
        if cnt > MAX_LOAD:
            fail("too many PT_LOAD segments")
        for q in loads:
            if p.vaddr < q.vaddr + q.memsz and q.vaddr < p.vaddr + p.memsz:
                fail("PT_LOAD segments overlap in address range")
        loads.append(p)
        if lo == nil or p.vaddr < lo:
            lo = p.vaddr
        if p.vaddr + p.memsz > hi:
            hi = p.vaddr + p.memsz
    if cnt == 0:
        fail("no loadable segments")
    return {min: page_down(lo), max: page_up(hi), loads: loads}

func vaddr_to_off(h, v):
    for p in h.ph:
        if p.type == PT_LOAD and v >= p.vaddr and v < p.vaddr + p.filesz:
            return p.offset + (v - p.vaddr)
    return -1

# -> {type, entry, min_vaddr, span, dynamic, static, interp, tls, relro, exec_stack, soname, rpath, runpath, needed[], tls_memsz, tls_align}
export func inspect(data):
    let d = as_u8(data)
    let h = parse_header(d)
    let v = validate_loads(h, len(d))
    let info = {type: h.type, entry: h.entry, min_vaddr: v.min, span: v.max - v.min, dynamic: false, static: false, interp: nil, tls: false, relro: false, exec_stack: false, soname: "", rpath: "", runpath: "", needed: [], tls_memsz: 0, tls_align: 0}
    let dynph = nil
    for p in h.ph:
        if p.type == PT_DYNAMIC:
            dynph = p
            info.dynamic = true
        elif p.type == PT_INTERP:
            if p.offset >= 0 and p.offset + p.filesz <= len(d):
                info.interp = cstr_at(d, p.offset, p.filesz)
        elif p.type == PT_TLS:
            info.tls = true
            info.tls_memsz = p.memsz
            info.tls_align = p.align if p.align != 0 else 1
        elif p.type == PT_GNU_STACK:
            info.exec_stack = (p.flags & 1) != 0
        elif p.type == PT_GNU_RELRO:
            info.relro = true
    if dynph == nil:
        info.static = true
        return info
    if dynph.offset + dynph.filesz > len(d):
        fail("PT_DYNAMIC outside file")
    let strtab = 0
    let so = 0
    let rp = 0
    let rup = 0
    let needed = []
    let k = 0
    while k + 16 <= dynph.filesz and k < 16 * 4096:
        let tag = u64(d, dynph.offset + k)
        let val = u64(d, dynph.offset + k + 8)
        k += 16
        if tag == 0:
            break
        if tag == 5:
            strtab = val
        elif tag == 14:
            so = val
        elif tag == 15:
            rp = val
        elif tag == 29:
            rup = val
        elif tag == 1:
            needed.append(val)
    if strtab == 0:
        return info
    let so_off = vaddr_to_off(h, strtab)
    if so_off < 0:
        fail("DT_STRTAB is not inside any PT_LOAD segment")
    if so != 0:
        info.soname = cstr_at(d, so_off + so, 4096)
    if rp != 0:
        info.rpath = cstr_at(d, so_off + rp, 4096)
    if rup != 0:
        info.runpath = cstr_at(d, so_off + rup, 4096)
    for nm in needed:
        let s = cstr_at(d, so_off + nm, 4096)
        if s != "":
            info.needed.append(s)
    return info

# ---------------------------------------------------------------------------------------------------------------------
# mapping an object
# ---------------------------------------------------------------------------------------------------------------------
const DT_NEEDED = 1
const DT_PLTRELSZ = 2
const DT_PLTGOT = 3
const DT_HASH = 4
const DT_STRTAB = 5
const DT_SYMTAB = 6
const DT_RELA = 7
const DT_RELASZ = 8
const DT_RELAENT = 9
const DT_STRSZ = 10
const DT_SYMENT = 11
const DT_INIT = 12
const DT_FINI = 13
const DT_SONAME = 14
const DT_RPATH = 15
const DT_REL = 17
const DT_RELSZ = 18
const DT_RELENT = 19
const DT_PLTREL = 20
const DT_TEXTREL = 22
const DT_JMPREL = 23
const DT_BIND_NOW = 24
const DT_INIT_ARRAY = 25
const DT_FINI_ARRAY = 26
const DT_INIT_ARRAYSZ = 27
const DT_FINI_ARRAYSZ = 28
const DT_RUNPATH = 29
const DT_FLAGS = 30
const DT_PREINIT_ARRAY = 32
const DT_PREINIT_ARRAYSZ = 33
const DT_RELRSZ = 35
const DT_RELR = 36
const DT_RELRENT = 37
const DT_GNU_HASH = 0x6ffffef5
const DT_FLAGS_1 = 0x6ffffffb
const DT_VERSYM = 0x6ffffff0
const DT_VERDEF = 0x6ffffffc
const DT_VERDEFNUM = 0x6ffffffd
const DT_VERNEED = 0x6ffffffe
const DT_VERNEEDNUM = 0x6fffffff

# Maps `data` at `base` (0 for ET_EXEC) into `space`, reads its dynamic section; returns the object.
export func map_object(space, data, base):
    let d = as_u8(data)
    let h = parse_header(d)
    let v = validate_loads(h, len(d))
    if h.type == 2:
        base = 0
    let start = base + v.min
    space.map(start, v.max - v.min)
    let obj = {base: base, type: h.type, entry: base + h.entry if h.entry != 0 else 0, map_start: start, map_end: start + (v.max - v.min), segs: [], phdr: 0, phentsize: h.phentsize, phnum: h.phnum, has_tls: false, tls_vaddr: 0, tls_filesz: 0, tls_memsz: 0, tls_align: 0, tls_modid: -1, tls_offset: 0, relro_start: 0, relro_size: 0, dynamic: false, nodelete: false, bind_now: false, textrel: false, ifuncs: [], symtab: 0, strtab: 0, strsz: 0, syment: 24, hash: 0, gnu_hash: 0, pltgot: 0, nsyms: 0, versym: 0, verdef: 0, verdefnum: 0, verneed: 0, verneednum: 0, soname_off: 0, rpath_off: 0, runpath_off: 0, needed: [], init: 0, fini: 0, init_array: 0, init_array_sz: 0, fini_array: 0, fini_array_sz: 0, preinit_array: 0, preinit_array_sz: 0, rela: 0, relasz: 0, relaent: 24, rel: 0, relsz: 0, relent: 16, relr: 0, relrsz: 0, relrent: 8, jmprel: 0, pltrelsz: 0, pltrel: DT_RELA, relocated: false}
    for p in v.loads:
        if p.filesz > 0:
            space.write_bytes(base + p.vaddr, d.slice(p.offset, p.offset + p.filesz), p.filesz)
        obj.segs.append({start: base + page_down(p.vaddr), end: base + page_up(p.vaddr + p.memsz), pflags: p.flags})
        if h.phoff >= p.offset and h.phoff + h.phnum * h.phentsize <= p.offset + p.filesz:
            obj.phdr = base + p.vaddr + (h.phoff - p.offset)
    let dyn_addr = 0
    let dyn_size = 0
    for p in h.ph:
        if p.type == PT_DYNAMIC:
            dyn_addr = base + p.vaddr
            dyn_size = p.memsz
            obj.dynamic = true
        elif p.type == PT_TLS:
            obj.has_tls = true
            obj.tls_vaddr = base + p.vaddr
            obj.tls_filesz = p.filesz
            obj.tls_memsz = p.memsz
            obj.tls_align = p.align
        elif p.type == PT_GNU_RELRO:
            obj.relro_start = base + p.vaddr
            obj.relro_size = p.memsz
    if obj.dynamic:
        scan_dynamic(space, obj, dyn_addr, dyn_size)
    return obj

func scan_dynamic(space, obj, addr, size):
    let bias = obj.base
    let flags = 0
    let flags1 = 0
    let k = 0
    while k + 16 <= size and k < 16 * 4096:
        let tag = space.r64(addr + k)
        let val = space.r64(addr + k + 8)
        k += 16
        if tag == 0:
            break
        if tag == DT_STRTAB:
            obj.strtab = bias + val
        elif tag == DT_STRSZ:
            obj.strsz = val
        elif tag == DT_SYMTAB:
            obj.symtab = bias + val
        elif tag == DT_SYMENT:
            obj.syment = val
        elif tag == DT_HASH:
            obj.hash = bias + val
        elif tag == DT_GNU_HASH:
            obj.gnu_hash = bias + val
        elif tag == DT_PLTGOT:
            obj.pltgot = bias + val
        elif tag == DT_RELA:
            obj.rela = bias + val
        elif tag == DT_RELASZ:
            obj.relasz = val
        elif tag == DT_RELAENT:
            obj.relaent = val
        elif tag == DT_REL:
            obj.rel = bias + val
        elif tag == DT_RELSZ:
            obj.relsz = val
        elif tag == DT_RELENT:
            obj.relent = val
        elif tag == DT_RELR:
            obj.relr = bias + val
        elif tag == DT_RELRSZ:
            obj.relrsz = val
        elif tag == DT_RELRENT:
            obj.relrent = val
        elif tag == DT_JMPREL:
            obj.jmprel = bias + val
        elif tag == DT_PLTRELSZ:
            obj.pltrelsz = val
        elif tag == DT_PLTREL:
            obj.pltrel = val
        elif tag == DT_INIT:
            obj.init = bias + val
        elif tag == DT_FINI:
            obj.fini = bias + val
        elif tag == DT_INIT_ARRAY:
            obj.init_array = bias + val
        elif tag == DT_INIT_ARRAYSZ:
            obj.init_array_sz = val
        elif tag == DT_FINI_ARRAY:
            obj.fini_array = bias + val
        elif tag == DT_FINI_ARRAYSZ:
            obj.fini_array_sz = val
        elif tag == DT_PREINIT_ARRAY:
            obj.preinit_array = bias + val
        elif tag == DT_PREINIT_ARRAYSZ:
            obj.preinit_array_sz = val
        elif tag == DT_VERSYM:
            obj.versym = bias + val
        elif tag == DT_VERDEF:
            obj.verdef = bias + val
        elif tag == DT_VERDEFNUM:
            obj.verdefnum = val
        elif tag == DT_VERNEED:
            obj.verneed = bias + val
        elif tag == DT_VERNEEDNUM:
            obj.verneednum = val
        elif tag == DT_SONAME:
            obj.soname_off = val
        elif tag == DT_RPATH:
            obj.rpath_off = val
        elif tag == DT_RUNPATH:
            obj.runpath_off = val
        elif tag == DT_NEEDED:
            obj.needed.append(val)
        elif tag == DT_FLAGS:
            flags = val
        elif tag == DT_FLAGS_1:
            flags1 = val
        elif tag == DT_TEXTREL:
            obj.textrel = true
        elif tag == DT_BIND_NOW:
            obj.bind_now = true
    if (flags & 4) != 0:
        obj.textrel = true
    if (flags & 8) != 0 or (flags1 & 1) != 0:
        obj.bind_now = true
    if (flags1 & 8) != 0:
        obj.nodelete = true

export func obj_string(space, obj, off):
    if obj.strtab == 0 or (obj.strsz != 0 and off >= obj.strsz):
        return nil
    return space.cstr(obj.strtab + off, 4096)

export func soname(space, obj):
    return obj_string(space, obj, obj.soname_off) if obj.soname_off != 0 else ""

# ---------------------------------------------------------------------------------------------------------------------
# symbols
# ---------------------------------------------------------------------------------------------------------------------
func elf_hash(name):
    let h = 0
    for c in str.to_bytes(name):
        h = ((h << 4) + c) & 0xffffffff
        let g = h & 0xf0000000
        if g != 0:
            h = h ^ (g >> 24)
        h = h & (~g) & 0xffffffff
    return h

func gnu_hash(name):
    let h = 5381
    for c in str.to_bytes(name):
        h = (h * 33 + c) & 0xffffffff
    return h

func read_sym(space, obj, idx):
    if obj.symtab == 0 or obj.syment < 24 or idx < 0 or (obj.nsyms != 0 and idx >= obj.nsyms):
        return nil
    let a = obj.symtab + idx * obj.syment
    return {name: space.r32(a), info: space.r8(a + 4), other: space.r8(a + 5), shndx: space.r16(a + 6), value: space.r64(a + 8), size: space.r64(a + 16)}

func sym_name_is(space, obj, st_name, want):
    if obj.strsz != 0 and st_name >= obj.strsz:
        return false
    return space.cstr(obj.strtab + st_name, 4096) == want

func compute_nsyms(space, obj):
    if obj.hash != 0:
        let nchain = space.r32(obj.hash + 4)
        if nchain != 0:
            return nchain
    if obj.gnu_hash != 0:
        let nb = space.r32(obj.gnu_hash)
        let symoff = space.r32(obj.gnu_hash + 4)
        let bloom = space.r32(obj.gnu_hash + 8)
        if nb == 0 or bloom == 0:
            return 0
        let buckets = obj.gnu_hash + 16 + bloom * 8
        let chains = buckets + nb * 4
        let last = 0
        for i in range(nb):
            let b = space.r32(buckets + i * 4)
            if b > last:
                last = b
        if last < symoff:
            let n = symoff
            if obj.strtab > obj.symtab and obj.syment >= 24 and (obj.strtab - obj.symtab) % obj.syment == 0:
                let dd = (obj.strtab - obj.symtab) // obj.syment
                if dd > n:
                    n = dd
            return n
        while true:
            let c = space.r32(chains + (last - symoff) * 4)
            last += 1
            if (c & 1) != 0:
                break
        return last
    return 0

# the version name symbol index `vidx` stands for (from this object's DT_VERDEF, then DT_VERNEED), or nil
func version_name(space, obj, vidx):
    vidx = vidx & 0x7fff
    if vidx <= 1:
        return nil
    if obj.verdef != 0 and obj.verdefnum != 0:
        let p = obj.verdef
        for i in range(obj.verdefnum):
            let ndx = space.r16(p + 4) & 0x7fff
            let cnt = space.r16(p + 6)
            let aux = space.r32(p + 12)
            let nxt = space.r32(p + 16)
            if ndx == vidx and cnt >= 1:
                return obj_string(space, obj, space.r32(p + aux))
            if nxt == 0:
                break
            p += nxt
    if obj.verneed != 0 and obj.verneednum != 0:
        let p = obj.verneed
        for i in range(obj.verneednum):
            let cnt = space.r16(p + 2)
            let a = p + space.r32(p + 8)
            let nxt = space.r32(p + 12)
            for j in range(cnt):
                if (space.r16(a + 6) & 0x7fff) == vidx:
                    return obj_string(space, obj, space.r32(a + 8))
                let an = space.r32(a + 12)
                if an == 0:
                    break
                a += an
            if nxt == 0:
                break
            p += nxt
    return nil

func version_matches(space, obj, idx, want):
    if obj.versym == 0:
        return want == nil
    let vs = space.r16(obj.versym + idx * 2)
    let is_default = (vs & 0x8000) == 0
    if want == nil:
        return is_default
    let have = version_name(space, obj, vs)
    return have != nil and have == want

func sym_value(obj, s):
    let t = s.info & 15
    if t == 6:
        return {address: 0, size: s.size, is_tls: true, tls_modid: obj.tls_modid, tls_offset: s.value, tls_tp_offset: s.value - obj.tls_offset, type: t, bind: s.info >> 4, obj: obj}
    let a = s.value if s.shndx == 0xfff1 else obj.base + s.value
    return {address: a, size: s.size, is_tls: false, tls_modid: 0, tls_offset: 0, tls_tp_offset: 0, type: t, bind: s.info >> 4, obj: obj}

func lookup_gnu(space, obj, name, ver):
    let nb = space.r32(obj.gnu_hash)
    let symoff = space.r32(obj.gnu_hash + 4)
    let bloom_size = space.r32(obj.gnu_hash + 8)
    let shift = space.r32(obj.gnu_hash + 12)
    if nb == 0 or bloom_size == 0 or shift >= 64:
        return nil
    let bloom = obj.gnu_hash + 16
    let buckets = bloom + bloom_size * 8
    let chains = buckets + nb * 4
    let h1 = gnu_hash(name)
    let word = space.r64(bloom + ((h1 // 64) % bloom_size) * 8)
    let mask = (1 << (h1 % 64)) | (1 << ((h1 >> shift) % 64))
    if (word & mask) != mask:
        return nil
    let n = space.r32(buckets + (h1 % nb) * 4)
    if n < symoff:
        return nil
    while true:
        let h2 = space.r32(chains + (n - symoff) * 4)
        if ((h1 ^ h2) >> 1) == 0:
            let s = read_sym(space, obj, n)
            if s != nil and s.shndx != 0 and sym_name_is(space, obj, s.name, name) and version_matches(space, obj, n, ver):
                return sym_value(obj, s)
        if (h2 & 1) != 0:
            break
        n += 1
    return nil

func lookup_sysv(space, obj, name, ver):
    let nbucket = space.r32(obj.hash)
    let nchain = space.r32(obj.hash + 4)
    if nbucket == 0 or nchain == 0:
        return nil
    let idx = space.r32(obj.hash + 8 + (elf_hash(name) % nbucket) * 4)
    let guard = 0
    while idx != 0 and guard < nchain:
        let s = read_sym(space, obj, idx)
        if s != nil and s.shndx != 0 and sym_name_is(space, obj, s.name, name) and version_matches(space, obj, idx, ver):
            return sym_value(obj, s)
        idx = space.r32(obj.hash + 8 + nbucket * 4 + idx * 4)
        if idx >= nchain:
            break
        guard += 1
    return nil

func lookup_linear(space, obj, name, ver):
    let limit = obj.nsyms
    if limit == 0:
        let span = (obj.strtab - obj.symtab) // obj.syment if obj.strtab > obj.symtab else 0
        limit = span if span != 0 and span < 65536 else 65536
    for i in range(limit):
        let s = read_sym(space, obj, i)
        if s == nil:
            break
        if s.name == 0 or s.shndx == 0:
            continue
        if obj.strsz != 0 and s.name >= obj.strsz:
            continue
        if sym_name_is(space, obj, s.name, name) and version_matches(space, obj, i, ver):
            return sym_value(obj, s)
    return nil

# -> {address, size, is_tls, tls_modid, tls_offset, tls_tp_offset, type, bind, obj} or nil.  ver: version name or nil.
export func lookup(space, obj, name, ver):
    if obj.symtab == 0 or obj.strtab == 0 or obj.syment == 0:
        return nil
    if obj.nsyms == 0:
        obj.nsyms = compute_nsyms(space, obj)
    let r = nil
    if obj.gnu_hash != 0:
        r = lookup_gnu(space, obj, name, ver)
    if r == nil and obj.hash != 0:
        r = lookup_sysv(space, obj, name, ver)
    if r == nil and obj.gnu_hash == 0 and obj.hash == 0:
        r = lookup_linear(space, obj, name, ver)
    return r

# the function / object symbol covering `addr` (dladdr): {name, address} or nil
export func symbol_at(space, obj, addr):
    if obj.symtab == 0 or obj.strtab == 0:
        return nil
    if obj.nsyms == 0:
        obj.nsyms = compute_nsyms(space, obj)
    let best = nil
    for i in range(1, obj.nsyms):
        let s = read_sym(space, obj, i)
        let t = s.info & 15
        if s.shndx == 0 or s.name == 0 or t > 2:
            continue
        let a = obj.base + s.value
        if a > addr:
            continue
        if s.size != 0:
            if addr >= a + s.size:
                continue
        elif addr - a > 0x10000:
            continue
        if best == nil or a > best.address:
            best = {name_off: s.name, address: a}
    if best == nil:
        return nil
    return {name: obj_string(space, obj, best.name_off), address: best.address}

# ---------------------------------------------------------------------------------------------------------------------
# relocation
# ---------------------------------------------------------------------------------------------------------------------
const R_NONE = 0
const R_64 = 1
const R_PC32 = 2
const R_PLT32 = 4
const R_COPY = 5
const R_GLOB_DAT = 6
const R_JUMP_SLOT = 7
const R_RELATIVE = 8
const R_32 = 10
const R_32S = 11
const R_16 = 12
const R_PC16 = 13
const R_8 = 14
const R_PC8 = 15
const R_DTPMOD64 = 16
const R_DTPOFF64 = 17
const R_TPOFF64 = 18
const R_PC64 = 24
const R_SIZE32 = 32
const R_SIZE64 = 33
const R_TLSDESC = 36
const R_IRELATIVE = 37
const R_RELATIVE64 = 38

func write_sized(space, target, value, width, signed):
    if width == 8:
        space.w64(target, value)
    elif width == 4:
        if signed:
            if value < -2147483648 or value > 2147483647:
                fail("32-bit signed relocation overflows")
        elif value < 0 or value > 0xffffffff:
            fail("32-bit relocation overflows")
        space.w32(target, value & 0xffffffff)
    elif width == 2:
        if value > 0xffff or value < -32768:
            fail("16-bit relocation overflows")
        space.w16(target, value & 0xffff)
    else:
        space.w8(target, value & 255)

# resolver(req) -> symval or nil;  req = {name, version, requester, weak, func, object, tls, ifunc, copy}
func resolve_for_reloc(space, obj, sidx, rtype, resolver):
    if sidx == 0:
        return {address: 0, size: 0, is_tls: true, tls_modid: obj.tls_modid, tls_offset: 0, tls_tp_offset: 0 - obj.tls_offset, weak: false, ifunc: false}
    let s = read_sym(space, obj, sidx)
    if s == nil:
        fail("relocation names a symbol outside the symbol table")
    let bind = s.info >> 4
    let t = s.info & 15
    let weak = bind == 2
    let ifunc = t == 10
    if s.shndx != 0 and rtype != R_COPY:
        let v = sym_value(obj, s)
        v.weak = weak
        v.ifunc = ifunc
        return v
    let name = obj_string(space, obj, s.name)
    if name == nil:
        fail("could not read the name of a relocated symbol")
    let ver = nil
    if obj.versym != 0:
        ver = version_name(space, obj, space.r16(obj.versym + sidx * 2))
    let req = {name: name, version: ver, requester: obj, weak: weak, func: t == 2, object: t == 1, tls: t == 6, ifunc: ifunc, copy: rtype == R_COPY}
    let v = resolver(req) if resolver != nil else nil
    if v != nil:
        v.weak = weak
        v.ifunc = ifunc
        return v
    if weak:
        return {address: 0, size: 0, is_tls: false, tls_modid: 0, tls_offset: 0, tls_tp_offset: 0, weak: true, ifunc: false}
    fail("undefined symbol: " .. name)

func apply_reloc(space, obj, r_offset, r_info, addend, resolver):
    let rtype = r_info & 0xffffffff
    let sidx = (r_info >> 32) & 0xffffffff
    if rtype == R_NONE:
        return nil
    let target = obj.base + r_offset
    if target < obj.map_start or target + 8 > obj.map_end:
        fail("relocation target outside the object at 0x" .. hex(target))
    let A = addend
    let P = target
    let B = obj.base
    if rtype == R_RELATIVE or rtype == R_RELATIVE64:
        space.w64(target, B + A)
        return nil
    if rtype == R_IRELATIVE:
        obj.ifuncs.append({target: target, resolver: B + A})
        space.w64(target, 0)
        return nil
    let sv = resolve_for_reloc(space, obj, sidx, rtype, resolver)
    let S = sv.address
    if sv.ifunc and S != 0 and (rtype == R_64 or rtype == R_GLOB_DAT or rtype == R_JUMP_SLOT):
        obj.ifuncs.append({target: target, resolver: S})
        space.w64(target, 0)
        return nil
    if rtype == R_64 or rtype == R_GLOB_DAT or rtype == R_JUMP_SLOT:
        write_sized(space, target, S + A, 8, false)
    elif rtype == R_PC32 or rtype == R_PLT32:
        write_sized(space, target, S + A - P, 4, true)
    elif rtype == R_PC64:
        write_sized(space, target, S + A - P, 8, false)
    elif rtype == R_32:
        write_sized(space, target, S + A, 4, false)
    elif rtype == R_32S:
        write_sized(space, target, S + A, 4, true)
    elif rtype == R_16:
        write_sized(space, target, S + A, 2, false)
    elif rtype == R_PC16:
        write_sized(space, target, S + A - P, 2, true)
    elif rtype == R_8:
        write_sized(space, target, S + A, 1, false)
    elif rtype == R_PC8:
        write_sized(space, target, S + A - P, 1, true)
    elif rtype == R_SIZE32:
        write_sized(space, target, sv.size + A, 4, false)
    elif rtype == R_SIZE64:
        write_sized(space, target, sv.size + A, 8, false)
    elif rtype == R_COPY:
        if sv.size == 0:
            return nil
        if target + sv.size > obj.map_end:
            fail("COPY relocation would write past the object")
        space.write_bytes(target, space.read_bytes(S, sv.size), sv.size)
    elif rtype == R_DTPMOD64:
        write_sized(space, target, sv.tls_modid if (sv.is_tls and sv.tls_modid > 0) else 0, 8, false)
    elif rtype == R_DTPOFF64:
        if not sv.is_tls and not sv.weak:
            fail("DTPOFF64 against a non-TLS symbol")
        write_sized(space, target, sv.tls_offset + A, 8, false)
    elif rtype == R_TPOFF64:
        if not sv.is_tls and not sv.weak:
            fail("TPOFF64 against a non-TLS symbol")
        write_sized(space, target, sv.tls_tp_offset + A, 8, false)
    elif rtype == R_TLSDESC or rtype == 35:
        fail("TLSDESC relocations are not supported (rebuild with -mtls-dialect=gnu or link with -z notlsdesc)")
    elif rtype == 3 or rtype == 9 or rtype == 19 or rtype == 20 or rtype == 21 or rtype == 22 or rtype == 23 or rtype == 25 or rtype == 26:
        fail("link-time-only relocation type in a loadable image (was this linked with -r?)")
    else:
        fail("unsupported relocation type " .. to_string(rtype))

func apply_table(space, obj, addr, size, entsize, is_rela, resolver):
    if addr == 0 or size == 0:
        return nil
    if entsize < (24 if is_rela else 16):
        fail("relocation entry size smaller than a real entry")
    let count = size // entsize
    if count > MAX_RELOCS:
        fail("too many relocations")
    for i in range(count):
        let a = addr + i * entsize
        let off = space.r64(a)
        let info = space.r64(a + 8)
        let add = space.r64(a + 16) if is_rela else space.r64(obj.base + off)
        apply_reloc(space, obj, off, info, add, resolver)

func apply_relr(space, obj, addr, size, entsize):
    if addr == 0 or size == 0:
        return nil
    if entsize < 8:
        fail("DT_RELRENT smaller than a word")
    let where = 0
    for i in range(size // entsize):
        let e = space.r64(addr + i * entsize)
        if (e & 1) == 0:
            where = obj.base + e
            if where < obj.map_start or where + 8 > obj.map_end:
                fail("RELR address outside the object")
            space.w64(where, space.r64(where) + obj.base)
            where += 8
        else:
            let bits = (e >> 1) & 0x7fffffffffffffff
            let p = where
            for b in range(63):
                if (bits >> b) & 1 != 0:
                    if p < obj.map_start or p + 8 > obj.map_end:
                        fail("RELR bitmap address outside the object")
                    space.w64(p, space.r64(p) + obj.base)
                p += 8
            where += 63 * 8

export func relocate(space, obj, resolver):
    if not obj.dynamic:
        return nil
    if obj.nsyms == 0:
        obj.nsyms = compute_nsyms(space, obj)
    apply_table(space, obj, obj.rela, obj.relasz, obj.relaent, true, resolver)
    apply_table(space, obj, obj.rel, obj.relsz, obj.relent, false, resolver)
    apply_relr(space, obj, obj.relr, obj.relrsz, obj.relrent)
    apply_table(space, obj, obj.jmprel, obj.pltrelsz, obj.relent if obj.pltrel == DT_REL else obj.relaent, obj.pltrel != DT_REL, resolver)
    obj.relocated = true

# ---------------------------------------------------------------------------------------------------------------------
# TLS, variant II (x86-64): module blocks lie below the thread pointer
# ---------------------------------------------------------------------------------------------------------------------
const TCB_SIZE = 64

export func tls_region_size(block, modules):
    return align_up(block + TCB_SIZE + (modules + 1) * 8, 64)

# assigns obj.tls_modid / obj.tls_offset; -> {block_size, align}
export func tls_layout(objs):
    let offset = 0
    let max_align = 8
    let modid = 0
    for o in objs:
        if not o.has_tls or o.tls_memsz == 0:
            o.tls_modid = -1
            o.tls_offset = 0
            continue
        let a = o.tls_align if o.tls_align != 0 else 8
        if (a & (a - 1)) != 0:
            a = 8
        if a > 65536:
            fail("PT_TLS alignment is implausible")
        if a > max_align:
            max_align = a
        offset = align_up(offset + o.tls_memsz, a)
        if offset > MAX_SEGMENT:
            fail("static TLS block is too large")
        modid += 1
        o.tls_modid = modid
        o.tls_offset = offset
    return {block_size: align_up(offset, max_align), align: max_align}

# builds the static TLS block in the (already mapped, zeroed) region; -> {block_addr, block_size, tp, dtv, modules}
export func tls_init(space, region, region_size, objs):
    let l = tls_layout(objs)
    let modules = 0
    for o in objs:
        if o.tls_modid > 0:
            modules += 1
    let need = tls_region_size(l.block_size, modules)
    if region_size < need:
        fail("TLS region too small for the static TLS block")
    let tp = align_up(region + l.block_size, l.align)
    if tp + TCB_SIZE + (modules + 1) * 8 > region + region_size:
        fail("TLS alignment pushes the TCB past the region")
    let dtv = tp + TCB_SIZE
    for o in objs:
        if o.tls_modid <= 0:
            continue
        let dest = tp - o.tls_offset
        if dest < region or dest + o.tls_memsz > tp:
            fail("a TLS module does not fit in the computed block")
        if o.tls_filesz != 0:
            space.write_bytes(dest, space.read_bytes(o.tls_vaddr, o.tls_filesz), o.tls_filesz)
        space.w64(dtv + o.tls_modid * 8, dest)
    space.w64(tp, tp)
    space.w64(tp + 8, dtv)
    space.w64(dtv, modules)
    return {block_addr: region, block_size: l.block_size, tp: tp, dtv: dtv, modules: modules}

# ---------------------------------------------------------------------------------------------------------------------
# the dynamic linker: one namespace (one process)
# ---------------------------------------------------------------------------------------------------------------------
const LIB_BASE = 0x7f0000000000
const LIB_ALIGN = 0x10000
const MAX_OBJECTS = 32
const MAX_DEPTH = 8
const TLS_BASE = 0x7e0000000000

func dirname(p):
    let i = len(p) - 1
    while i >= 0 and p.slice(i, i + 1) != "/":
        i -= 1
    if i <= 0:
        return "/"
    return p.slice(0, i)

func join(dir, name):
    if dir.slice(len(dir) - 1, len(dir)) == "/":
        return dir .. name
    return dir .. "/" .. name

func split_list(s):
    let out = []
    let cur = ""
    for i in range(len(s)):
        let c = s.slice(i, i + 1)
        if c == ":":
            if cur != "":
                out.append(cur)
            cur = ""
        else:
            cur = cur .. c
    if cur != "":
        out.append(cur)
    return out

# $ORIGIN / ${ORIGIN} in a RPATH / RUNPATH entry stand for the directory of the object that carries it
func replace_origin(dir, origin):
    for tok in ["${ORIGIN}", "$ORIGIN"]:
        let i = dir.find(tok)
        if i >= 0:
            return dir.slice(0, i) .. origin .. dir.slice(i + len(tok), len(dir))
    return dir

func is_elf(b):
    return b != nil and len(b) >= 4 and b[0] == 0x7f and b[1] == 0x45 and b[2] == 0x4c and b[3] == 0x46

# space: a Space(); read_file(path) -> bytes or nil
export func Linker(space, read_file):
    let objs = []  # slots: nil or {obj, path, soname, global, refcount, nodelete, serial, needs, is_main, vlo, vhi}
    let next_serial = 0
    let next_base = LIB_BASE
    let search_path = ["/lib", "/usr/lib", "/"]
    let user_path = []
    let last_error = ""
    let tls = nil

    func set_error(msg):
        if last_error == "":
            last_error = msg

    func alloc_base(span):
        let b = align_up(next_base, LIB_ALIGN)
        let e = b + align_up(span, LIB_ALIGN)
        next_base = e
        return b

    func slot_count():
        return len(objs)

    func find_loaded(path, so):
        for i in range(len(objs)):
            let s = objs[i]
            if s == nil:
                continue
            if s.path == path:
                return i
            if so != "" and s.soname == so:
                return i
        return -1

    func try_dir(dir, name, origin = nil):
        if origin != nil:
            dir = replace_origin(dir, origin)
        let p = join(dir, name)
        if is_elf(read_file(p)):
            return p
        return nil

    func resolve_needed(requester, name):
        if name == "":
            return nil
        if name.slice(0, 1) == "/":
            return name if is_elf(read_file(name)) else nil
        if requester != nil:
            let o = requester.obj
            if o.runpath_off != 0:
                let l = obj_string(space, o, o.runpath_off)
                if l != nil:
                    for dir in split_list(l):
                        let p = try_dir(dir, name, dirname(requester.path))
                        if p != nil:
                            return p
            if o.rpath_off != 0:
                let l = obj_string(space, o, o.rpath_off)
                if l != nil:
                    for dir in split_list(l):
                        let p = try_dir(dir, name, dirname(requester.path))
                        if p != nil:
                            return p
            let p = try_dir(dirname(requester.path), name)
            if p != nil:
                return p
        for dir in user_path:
            let p = try_dir(dir, name)
            if p != nil:
                return p
        for dir in search_path:
            let p = try_dir(dir, name)
            if p != nil:
                return p
        return nil

    # scope: the global objects in load order, then (for the asker) the libraries it depends on
    func make_resolver(deepbind):
        func resolve(req):
            let asker = -1
            for i in range(len(objs)):
                if objs[i] != nil and objs[i].obj == req.requester:
                    asker = i
            if deepbind != nil and deepbind == req.requester and not req.copy:
                let v = lookup(space, deepbind, req.name, req.version)
                if v != nil:
                    return v
            let global_set = []
            for i in range(len(objs)):
                if objs[i] != nil and objs[i].global:
                    global_set.append(i)
            let closure = []
            if asker >= 0:
                let seen = {}
                let frontier = []
                for j in objs[asker].needs:
                    frontier.append(j)
                    seen[to_string(j)] = true
                while len(frontier) > 0:
                    let nxt = []
                    for j in frontier:
                        if objs[j] != nil:
                            for k in objs[j].needs:
                                if seen[to_string(k)] == nil:
                                    seen[to_string(k)] = true
                                    nxt.append(k)
                    frontier = nxt
                for i in range(len(objs)):
                    if seen[to_string(i)] != nil and not (objs[i] != nil and objs[i].global):
                        closure.append(i)
            for attempt in range(2 if req.version != nil else 1):
                let ver = req.version if attempt == 0 else nil
                for list in [global_set, closure]:
                    for i in list:
                        let s = objs[i]
                        if s == nil:
                            continue
                        if req.copy and s.obj == req.requester:
                            continue
                        let v = lookup(space, s.obj, req.name, ver)
                        if v != nil:
                            if asker >= 0 and asker != i and not objs[asker].needs.contains(i):
                                objs[asker].needs.append(i)
                            return v
            return nil
        return resolve

    # maps one object and (recursively) its dependencies, without relocating; -> slot or -1
    func load_object(path, global, depth, requester, fresh):
        if depth >= MAX_DEPTH:
            set_error("dependency chain too deep")
            return -1
        let bytes = read_file(path)
        if not is_elf(bytes):
            set_error("cannot read " .. path)
            return -1
        let b = as_u8(bytes)
        let info = inspect(b)
        let have = find_loaded(path, info.soname)
        if have >= 0:
            if requester >= 0 and requester != have and not objs[requester].needs.contains(have):
                objs[requester].needs.append(have)
            if global:
                objs[have].global = true
            return have
        let slot = -1
        for i in range(len(objs)):
            if objs[i] == nil:
                slot = i
                break
        if slot < 0:
            if len(objs) >= MAX_OBJECTS:
                set_error("no free object slot")
                return -1
            objs.append(nil)
            slot = len(objs) - 1
        let base = alloc_base(info.span)
        let obj = map_object(space, b, base - page_down(info.min_vaddr) if info.min_vaddr != 0 else base)
        next_serial += 1
        objs[slot] = {obj: obj, path: path, soname: info.soname, global: global, refcount: 0, nodelete: obj.nodelete, serial: next_serial, needs: [], is_main: false, vlo: obj.map_start, vhi: obj.map_end}
        fresh.append(slot)
        if requester >= 0 and requester != slot:
            objs[requester].needs.append(slot)
        for nm in info.needed:
            let dep = resolve_needed(objs[slot], nm)
            if dep == nil:
                set_error("cannot find dependency " .. nm)
                return -1
            if load_object(dep, global, depth + 1, slot, fresh) < 0:
                return -1
        return slot

    func unload_slot(j):
        let s = objs[j]
        if s == nil:
            return nil
        space.unmap(s.vlo, s.vhi)
        objs[j] = nil
        for k in range(len(objs)):
            if objs[k] != nil:
                let keep = []
                for q in objs[k].needs:
                    if q != j:
                        keep.append(q)
                objs[k].needs = keep

    func order_by_serial(list, descending):
        let out = []
        for j in list:
            out.append(j)
        let n = len(out)
        for a in range(1, n):
            let v = out[a]
            let b = a - 1
            while b >= 0 and ((objs[out[b]].serial < objs[v].serial) if descending else (objs[out[b]].serial > objs[v].serial)):
                out[b + 1] = out[b]
                b -= 1
            out[b + 1] = v
        return out

    func setup_tls():
        let set = []
        let any = false
        for s in objs:
            if s != nil:
                set.append(s.obj)
                if s.obj.has_tls:
                    any = true
        if not any:
            tls = nil
            return nil
        let l = tls_layout(set)
        let modules = 0
        for o in set:
            if o.tls_modid > 0:
                modules += 1
        let need = tls_region_size(l.block_size, modules) + l.align + PAGE
        space.map(TLS_BASE, need)
        tls = tls_init(space, TLS_BASE, need, set)

    func load_executable(path, bytes, base):
        let b = as_u8(bytes)
        let info = inspect(b)
        if info.type == 3 and info.entry == 0:
            fail("refusing to run a shared object as a program")
        if info.interp != nil:
            fail("program requests an interpreter this system does not provide: " .. info.interp)
        let obj = map_object(space, b, base)
        next_serial += 1
        objs.append({obj: obj, path: path, soname: info.soname, global: true, refcount: 1, nodelete: true, serial: next_serial, needs: [], is_main: true, vlo: obj.map_start, vhi: obj.map_end})
        let fresh = []
        last_error = ""
        for nm in info.needed:
            let dep = resolve_needed(objs[0], nm)
            if dep == nil:
                fail("cannot find dependency " .. nm)
            if load_object(dep, true, 1, 0, fresh) < 0:
                fail(last_error)
        let set = []
        for s in objs:
            if s != nil:
                set.append(s.obj)
        tls_layout(set)
        let res = make_resolver(nil)
        let i = len(objs) - 1
        while i >= 0:
            if objs[i] != nil:
                relocate(space, objs[i].obj, res)
            i -= 1
        setup_tls()
        return obj

    func handle(slot):
        return (objs[slot].serial << 8) | (slot + 1)

    func handle_slot(h):
        if h == nil or h <= 0:
            return -1
        let slot = (h & 255) - 1
        let serial = h >> 8
        if slot < 0 or slot >= len(objs) or objs[slot] == nil or objs[slot].serial != serial:
            return -1
        return slot

    func dlopen(path, flags):
        last_error = ""
        let resolved = resolve_needed(objs[0] if len(objs) > 0 else nil, path)
        if resolved == nil:
            set_error("cannot find " .. path)
            return nil
        if (flags & RTLD_NOLOAD) != 0:
            let h = find_loaded(resolved, "")
            if h < 0:
                set_error("not loaded: " .. path)
                return nil
            objs[h].refcount += 1
            if (flags & RTLD_GLOBAL) != 0:
                objs[h].global = true
            return handle(h)
        let fresh = []
        let slot = load_object(resolved, (flags & RTLD_GLOBAL) != 0, 1, -1, fresh)
        let ok = slot >= 0
        let order = order_by_serial(fresh, true)
        if ok:
            for j in order:
                if objs[j].obj.has_tls and tls != nil:
                    set_error("has thread-local storage, which cannot be added after startup: " .. objs[j].path)
                    ok = false
        if ok:
            for j in order:
                objs[j].global = true
            try:
                for j in order:
                    let df = objs[j].obj if (j == slot and (flags & RTLD_DEEPBIND) != 0) else nil
                    relocate(space, objs[j].obj, make_resolver(df))
            catch e:
                set_error(e.message)
                ok = false
            if ok:
                for j in order:
                    if (flags & RTLD_GLOBAL) == 0:
                        objs[j].global = false
                if (flags & RTLD_GLOBAL) != 0:
                    objs[slot].global = true
                if (flags & RTLD_NODELETE) != 0:
                    objs[slot].nodelete = true
                objs[slot].refcount += 1
        if not ok:
            for j in fresh:
                unload_slot(j)
            return nil
        return handle(slot)

    func dlsym(h, name):
        last_error = ""
        let found = nil
        if h == RTLD_DEFAULT:
            for s in objs:
                if s != nil and s.global:
                    found = lookup(space, s.obj, name, nil)
                    if found != nil:
                        break
        else:
            let slot = handle_slot(h)
            if slot < 0:
                set_error("invalid handle")
                return nil
            let seen = [slot]
            let frontier = [slot]
            while found == nil and len(frontier) > 0:
                let nxt = []
                for j in frontier:
                    found = lookup(space, objs[j].obj, name, nil)
                    if found != nil:
                        break
                    for k in objs[j].needs:
                        if not seen.contains(k):
                            seen.append(k)
                            nxt.append(k)
                frontier = nxt
        if found == nil:
            set_error("undefined symbol: " .. name)
            return nil
        if found.is_tls:
            set_error("thread-local symbol: " .. name)
            return nil
        return found.address

    # the slots a close of `top` would leave unreferenced (transitively)
    func unload_set(top):
        let refs = []
        for s in objs:
            refs.append(s.refcount if s != nil else 0)
        if top >= 0 and refs[top] > 0:
            refs[top] -= 1
        let gone = []
        let changed = true
        while changed:
            changed = false
            for j in range(len(objs)):
                let s = objs[j]
                if s == nil or s.is_main or s.nodelete or refs[j] != 0 or gone.contains(j):
                    continue
                let needed = false
                for k in range(len(objs)):
                    if k != j and objs[k] != nil and not gone.contains(k) and objs[k].needs.contains(j):
                        needed = true
                if not needed:
                    gone.append(j)
                    changed = true
        return gone

    func dlclose(h):
        last_error = ""
        let slot = handle_slot(h)
        if slot < 0:
            set_error("invalid handle")
            return false
        let s = objs[slot]
        if s.is_main or s.refcount == 0:
            set_error("not an open handle")
            return false
        s.refcount -= 1
        for j in unload_set(-1):
            unload_slot(j)
        return true

    func dlerror():
        let e = last_error
        last_error = ""
        return e

    func set_search_path(l):
        search_path = split_list(l)

    func set_library_path(l):
        user_path = split_list(l)

    func objects():
        let out = []
        for s in objs:
            if s != nil:
                out.append({path: s.path, soname: s.soname, base: s.obj.base, global: s.global, refcount: s.refcount, serial: s.serial})
        return out

    func object(i):
        return objs[i].obj if i < len(objs) and objs[i] != nil else nil

    func get_tls():
        return tls

    return {load_executable: load_executable, dlopen: dlopen, dlsym: dlsym, dlclose: dlclose, dlerror: dlerror, set_search_path: set_search_path, set_library_path: set_library_path, objects: objects, object: object, tls: get_tls, slot_count: slot_count}
