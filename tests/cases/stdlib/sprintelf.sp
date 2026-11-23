# sprintelf: inspect, symbol lookup (GNU hash / SysV hash / versions), relocation, TLS, the linker (DT_NEEDED, $ORIGIN, dlopen /
# dlsym / dlclose) and IFUNC deferral. Fixtures: tests/data/elf (tools/elf/mkfixtures.sh); tools/elf/exec_check.sp runs the relocated code for real.
import fs
import typed
import sprintelf

const DIR = "tests/data/elf/"

func read_file(path):
    let name = path
    let i = len(path) - 1
    while i >= 0 and path.slice(i, i + 1) != "/":
        i -= 1
    if i >= 0:
        name = path.slice(i + 1, len(path))
    try:
        return fs.read_bytes(DIR .. name)
    catch e:
        return nil

func hex(v):
    let digits = "0123456789abcdef"
    if v == 0:
        return "0"
    let s = ""
    while v != 0:
        s = digits.slice(v & 15, (v & 15) + 1) .. s
        v = v >> 4
    return s

# ---- inspect ----
for name in ["libb.so", "liba.so", "libv.so", "prog"]:
    let i = sprintelf.inspect(read_file(name))
    print(name, "type", i.type, "soname", i.soname, "needed", i.needed, "runpath", i.runpath, "tls", i.tls, "interp", i.interp, "relro", i.relro, "dynamic", i.dynamic)

# ---- lookup in all three hash styles ----
for name in ["libb.so", "libg.so", "libs.so"]:
    let sp = sprintelf.Space()
    let o = sprintelf.map_object(sp, read_file(name), 0x10000000)
    let line = name
    for sym in ["b_counter", "b_table", "b_add", "b_fp", "b_get_counter", "b_bump", "nosuch"]:
        let v = sprintelf.lookup(sp, o, sym, nil)
        line = line .. " " .. sym .. "=" .. ("-" if v == nil else hex(v.address - o.base) .. "/" .. to_string(v.size))
    print(line)
    let t = sprintelf.lookup(sp, o, "b_tls", nil)
    print(name, "tls symbol", t.is_tls, t.tls_offset)

# ---- symbol versions ----
let spv = sprintelf.Space()
let ov = sprintelf.map_object(spv, read_file("libv.so"), 0x20000000)
for ver in [nil, "V1", "V2", "V3"]:
    let v = sprintelf.lookup(spv, ov, "vf", ver)
    print("vf", ver, "->", "-" if v == nil else hex(v.address - ov.base))

# ---- TLS layout ----
let spt = sprintelf.Space()
let ot = sprintelf.map_object(spt, read_file("libb.so"), 0x30000000)
let lay = sprintelf.tls_layout([ot])
print("tls layout", lay.block_size, lay.align, ot.tls_modid, ot.tls_offset, ot.tls_memsz, ot.tls_filesz)

# ---- link a program with its libraries and run it ----
let sp = sprintelf.Space()
let ln = sprintelf.Linker(sp, read_file)
ln.set_library_path("/nowhere:/tests")
let prog = ln.load_executable("/x/prog", read_file("prog"), 0x555555554000)
for o in ln.objects():
    print("object", o.path, o.soname, hex(o.base), o.global, o.refcount)
let tls = ln.tls()
print("tls block", tls.block_size, tls.modules)

let nif = 0
for k in range(ln.slot_count()):
    nif += len(ln.object(k).ifuncs)
print("ifunc slots recorded", nif)
let main_run_sym = sprintelf.lookup(sp, prog, "main_run", nil)
print("main_run at", hex(main_run_sym.address - prog.base))
let tp_off = sprintelf.lookup(sp, ln.object(2), "b_tls", nil)
print("b_tls at tp+offset (the initial image) =", sp.r32(tls.tp + tp_off.tls_tp_offset))
print("dlsym default / missing:", ln.dlsym(0, "b_add") != nil, ln.dlsym(0, "nosuch"), ln.dlerror())

# ---- dlopen / dlsym / dlclose ----
let h = ln.dlopen("libv.so", 0)
print("dlopen libv", h != nil)
print("dlsym vf in handle", ln.dlsym(h, "vf") != nil, "default scope (RTLD_LOCAL)", ln.dlsym(0, "vf"))
print("dlclose", ln.dlclose(h), "again", ln.dlclose(h), ln.dlerror())
print("dlopen missing", ln.dlopen("libnone.so", 0), ln.dlerror())
let h2 = ln.dlopen("libv.so", sprintelf.RTLD_GLOBAL)
print("reopen global", h2 != nil, ln.dlsym(0, "v_user") != nil)
print("objects", len(ln.objects()))

# ---- RELR (packed relative relocations) ----
let spr = sprintelf.Space()
let lr = sprintelf.map_object(spr, read_file("libr.so"), 0x40000000)
print("relr table", lr.relrsz > 0, "rela", lr.relasz)
sprintelf.relocate(spr, lr, nil)
let tab = sprintelf.lookup(spr, lr, "r_table", nil)
let ok = true
for i in range(9):
    let p = spr.r64(tab.address + 8 * i)
    ok = ok and p > lr.base and p < lr.map_end
print("r_table entries point into the object", ok)

# ---- rejected input ----
func rejects(what, f):
    try:
        f()
        print(what, "accepted")
    catch e:
        print(what, e.kind)

let good = read_file("libb.so")
let junk = typed.u8(64)
for i in range(64):
    junk[i] = i + 1

func no_file(p):
    return nil

func t_magic():
    sprintelf.inspect(junk)

func t_trunc():
    sprintelf.inspect(good.slice(0, 100))

func t_lib_as_prog():
    sprintelf.Linker(sprintelf.Space(), read_file).load_executable("/x/libb.so", good, 0)

func t_missing_dep():
    sprintelf.Linker(sprintelf.Space(), no_file).load_executable("/x/prog", read_file("prog"), 0x555555554000)

rejects("bad magic", t_magic)
rejects("truncated", t_trunc)
rejects("shared object as program", t_lib_as_prog)
rejects("missing dependency", t_missing_dep)
