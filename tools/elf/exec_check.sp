# exec_check: loads the fixtures with sprintelf, copies the relocated image to real memory at the same addresses and RUNS it.
# usage (repository root, after make): build/sprint run --allow-read=tests/data/elf --allow-ffi tools/elf/exec_check.sp | diff - tools/elf/exec_check.out
# Not part of make test: ffi is never available there (--deterministic).
import fs
import ffi
import typed
import str
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

ffi.cdef("void *mmap(void *a, unsigned long n, int prot, int flags, int fd, long off);")
let libc = ffi.open(nil)
let mmap = libc.fn("mmap")
let synced = {}

# makes every region of the simulated address space real memory at the same address (RWX), copying its bytes
func sync_host(sp):
    for r in sp.regions():
        if synced[to_string(r.start)] == nil:
            let p = mmap(r.start, r.end - r.start, 7, 0x22 | 0x100000, -1, 0)
            if p != r.start:
                print("mmap failed", hex(r.start))
            synced[to_string(r.start)] = true
        ffi.view(r.start, "u8", r.end - r.start).fill_from(r.mem.to_array())

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

# the IFUNC slots: run the resolver (it is real code) and store the result
sync_host(sp)
for k in range(ln.slot_count()):
    let o = ln.object(k)
    for f in o.ifuncs:
        let res = ffi.fn_at(f.resolver, "long(void)")
        sp.w64(f.target, res())
        print("ifunc applied", hex(f.target - o.base))
sync_host(sp)
let main_run = ffi.fn_at(prog.base + (sprintelf.lookup(sp, prog, "main_run", nil).address - prog.base), "int(int)")
print("main_run(5) =", main_run(5))
let a_has_missing = ffi.fn_at(ln.dlsym(0, "a_has_missing"), "int(void)")
print("a_has_missing =", a_has_missing())
let a_call_ifunc = ffi.fn_at(ln.dlsym(0, "a_call_ifunc"), "int(void)")
print("a_call_ifunc =", a_call_ifunc())
let a_local = ffi.fn_at(ln.dlsym(0, "a_local"), "int(void)")
print("a_local =", a_local())
let ctr = ffi.fn_at(ln.dlsym(0, "a_counter_ptr"), "long(void)")
print("counter via a_counter_ptr (host memory) =", ffi.view(ctr(), "i32", 1).get(0))
let tp_off = sprintelf.lookup(sp, ln.object(2), "b_tls", nil)
print("b_tls through the thread pointer =", sp.r32(tls.tp + tp_off.tls_tp_offset))
print("dlsym default / missing:", ln.dlsym(0, "b_add") != nil, ln.dlsym(0, "nosuch"), ln.dlerror())

# ---- dlopen / dlsym / dlclose ----
let h = ln.dlopen("libv.so", 0)
print("dlopen libv", h != nil)
print("dlsym vf in handle", ln.dlsym(h, "vf") != nil, "default scope (RTLD_LOCAL)", ln.dlsym(0, "vf"))
sync_host(sp)
print("vf() =", ffi.fn_at(ln.dlsym(h, "vf"), "int(void)")())
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
sync_host(spr)
print("r_call(7) =", ffi.fn_at(sprintelf.lookup(spr, lr, "r_call", nil).address, "int(int)")(7))
