# linuxd: the Linux personality server. It runs x86-64 Linux programs (static-pie, or dynamic with their interpreter) as ordinary SprintOS processes whose
# system calls the kernel forwards to this process as messages. The kernel only has a handful of mechanisms for it (lx module: create a process, map /
# unmap / protect memory in it, copy bytes in and out, start it, answer a system call, kill it); everything Linux - the file descriptors, paths, the
# system call table, the ELF loader, the initial stack - is here, in Sprint, on top of the file system server.
#
# A client starts a program with the message  "run<TAB>path<TAB>arg0<US>arg1...<TAB>env0<US>env1..."  (US = byte 0x1f) and receives "ok<TAB>pid" or
# "err<TAB>why", and later "exit<TAB>pid<TAB>status" when the program ended. The server registers as "linux".
import io
import ipc
import lx
import psys
import fsclient
import sslcore

const USER_BASE = 0x8000000000
const STACK_TOP = USER_BASE + 0x40000000
const STACK_SIZE = 8 << 20
const PIE_BASE = USER_BASE + 0x400000
const INTERP_BASE = USER_BASE + 0x200000000
const MMAP_BASE = USER_BASE + 0x10000000
const AT_FDCWD = -100

const EPERM = 1
const ENOENT = 2
const EBADF = 9
const ECHILD = 10
const EAGAIN = 11
const ENOMEM = 12
const EACCES = 13
const EFAULT = 14
const EEXIST = 17
const ENOTDIR = 20
const EISDIR = 21
const EINVAL = 22
const EMFILE = 24
const ENOTTY = 25
const ESPIPE = 29
const ERANGE = 34
const ENOSYS = 38
const ENOTEMPTY = 39

let fs = nil
let guests = {}           # pid -> Guest
let table = {}            # system call number -> function(g, a)
let verbose = false

func log(s):
    print("[linuxd] " .. s)
    io.flush()

func align_up(v):
    return (v + 4095) & ~4095

func imin(a, b):
    return a if a < b else b

# ---- bytes ----
func u16(b, o):
    return b[o] | (b[o + 1] << 8)

func u32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)

func u64(b, o):
    return u32(b, o) | (u32(b, o + 4) << 32)

func put16(b, o, v):
    b[o] = v & 255
    b[o + 1] = (v >> 8) & 255

func put32(b, o, v):
    for i in range(4):
        b[o + i] = (v >> (8 * i)) & 255

func put64(b, o, v):
    for i in range(8):
        b[o + i] = (v >> (8 * i)) & 255

func putstr(b, o, s):
    let t = sslcore.from_str(s)
    for i in range(len(t)):
        b[o + i] = t[i]

func errno_of(kind):
    if kind == "ENOENT":
        return ENOENT
    if kind == "EEXIST":
        return EEXIST
    if kind == "ENOTDIR":
        return ENOTDIR
    if kind == "EISDIR":
        return EISDIR
    if kind == "ENOTEMPTY":
        return ENOTEMPTY
    if kind == "EINVAL":
        return EINVAL
    if kind == "ENOSPC":
        return 28
    if kind == "EACCES":
        return EACCES
    if kind == "ENODEV":
        return 19
    return 5      # EIO

# ---- a Linux program ----
class Guest:
    let pid = 0
    let client = 0
    let fds = nil
    let cwd = "/"
    let brk = 0
    let brk_end = 0           # the heap is mapped up to here (page aligned)
    let mmap_next = MMAP_BASE
    let exe = ""
    let calls = 0
    func init(self, pid, client):
        self.pid = pid
        self.client = client
        self.fds = {0: {kind: "stdin"}, 1: {kind: "console", fd: 1}, 2: {kind: "console", fd: 2}}
    func alloc_fd(self, f, start = 0):
        let n = start
        while self.fds[n] != nil:
            n += 1
        self.fds[n] = f
        return n

func rd(g, addr, n):
    if n == 0:
        return sslcore.concat([[]])
    return lx.read(g.pid, addr, n)

func wr(g, addr, b):
    if len(b) == 0:
        return 0
    return 0 if lx.write(g.pid, addr, b) == 0 else -EFAULT

# a C string from the program's memory (nil on a fault)
func cstr(g, addr):
    let parts = []
    let total = 0
    while total < 4096:
        let chunk = imin(4096 - ((addr + total) & 4095), 256)
        let b = rd(g, addr + total, chunk)
        if b == nil:
            return nil
        for i in range(len(b)):
            if b[i] == 0:
                parts.append(b.slice(0, i))
                return sslcore.to_text(sslcore.concat(parts))
        parts.append(b)
        total += chunk
    return nil

func norm(path):
    let out = []
    for part in path.split("/"):
        if part == "" or part == ".":
            continue
        if part == "..":
            if len(out) > 0:
                out.pop()
        else:
            out.append(part)
    return "/" .. out.join("/")

func abspath(g, p):
    if p.starts_with("/"):
        return norm(p)
    return norm(g.cwd .. "/" .. p)

# ---- the ELF loader ----
func load_elf(pid, img, bias):
    if len(img) < 64 or u32(img, 0) != 0x464C457F or img[4] != 2 or u16(img, 18) != 62:
        return "not an x86-64 ELF64 file"
    let typ = u16(img, 16)
    let phoff = u64(img, 32)
    let phent = u16(img, 54)
    let phnum = u16(img, 56)
    let segs = []
    let interp = nil
    let phdr = 0
    let lowest = -1
    let top = 0
    for i in range(phnum):
        let ph = phoff + i * phent
        let kind = u32(img, ph)
        let off = u64(img, ph + 8)
        let va = u64(img, ph + 16)
        let filesz = u64(img, ph + 32)
        let memsz = u64(img, ph + 40)
        if kind == 3:
            interp = sslcore.to_text(img.slice(off, off + filesz - 1))
        elif kind == 6:
            phdr = va
        elif kind == 1:
            if off + filesz > len(img):
                return "a segment lies outside the file"
            segs.append([va, off, filesz, memsz])
            if lowest < 0 or va < lowest:
                lowest = va
            if va + memsz > top:
                top = va + memsz
    if len(segs) == 0:
        return "no loadable segments"
    let b = 0
    if typ == 3:
        b = bias
    elif typ == 2:
        if lowest < USER_BASE:
            return "a fixed-address executable below 512 GiB cannot be loaded here (link it as -static-pie / -pie)"
    else:
        return "neither an executable nor a shared object"
    # one region per run of pages the segments touch, then the file bytes
    let ranges = []
    for s in segs:
        ranges.append([(s[0] + b) & ~4095, align_up(s[0] + b + s[3])])
    ranges.sort((x, y) => x[0] < y[0])
    let merged = []
    for r in ranges:
        if len(merged) > 0 and r[0] <= merged[len(merged) - 1][1]:
            if r[1] > merged[len(merged) - 1][1]:
                merged[len(merged) - 1][1] = r[1]
        else:
            merged.append([r[0], r[1]])
    for r in merged:
        if lx.map(pid, r[0], r[1] - r[0], 3) != 0:
            return "cannot map the program"
    for s in segs:
        if s[2] > 0 and lx.write(pid, s[0] + b, img, s[1], s[2]) != 0:
            return "cannot copy a segment"
    let first_load = segs[0]
    if phdr == 0:
        phdr = first_load[0] - first_load[1] + phoff
    return {entry: u64(img, 24) + b, phdr: phdr + b, phent: phent, phnum: phnum, base: b, top: align_up(top + b), interp: interp}

func read_file(path):
    return fs.read_bytes(path)

# the initial stack: argc, argv, envp and the auxiliary vector; returns the stack pointer
func build_stack(pid, argv, envp, info, interp_base):
    # strings first (at the top), then the random bytes, then the vectors
    let strs = []
    let top = STACK_TOP
    let area = []           # bytes from the bottom of the string area up
    let pos = {}
    func add(s):
        let off = len(area)
        let b = sslcore.from_str(s)
        for x in b:
            area.append(x)
        area.append(0)
        return off
    let aoff = []
    for a in argv:
        aoff.append(add(a))
    let eoff = []
    for e in envp:
        eoff.append(add(e))
    let plat = add("x86_64")
    let exe = add(argv[0] if len(argv) > 0 else "")
    let rnd = len(area)
    for i in range(16):
        area.append((i * 37 + 11) & 255)
    let rb = sslcore.random(16)
    for i in range(16):
        area[rnd + i] = rb[i]
    while len(area) % 16 != 0:
        area.append(0)
    let abase = STACK_TOP - len(area)
    let aux = [[3, info.phdr], [4, info.phent], [5, info.phnum], [6, 4096], [7, interp_base], [8, 0], [9, info.entry], [11, 0], [12, 0], [13, 0], [14, 0],
               [15, abase + plat], [16, 0], [17, 100], [23, 0], [25, abase + rnd], [31, abase + exe], [0, 0]]
    let nwords = 1 + len(argv) + 1 + len(envp) + 1 + 2 * len(aux)
    let sp = (abase - nwords * 8) & ~15
    let words = [len(argv)]
    for o in aoff:
        words.append(abase + o)
    words.append(0)
    for o in eoff:
        words.append(abase + o)
    words.append(0)
    for x in aux:
        words.append(x[0])
        words.append(x[1])
    let buf = []
    for w in words:
        for i in range(8):
            buf.append((w >> (8 * i)) & 255)
    let all = sslcore.concat([buf, area])
    if lx.write(pid, sp, all) != 0:
        return nil
    return sp

# start the program at `path`; returns [pid] or an error string
func start_program(client, path, argv, envp):
    let img = nil
    try:
        img = read_file(path)
    catch e:
        return "cannot read " .. path .. ": " .. to_string(e)
    let pid = lx.create()
    if pid < 0:
        return "lx.create failed (" .. to_string(pid) .. ")"
    let info = load_elf(pid, img, PIE_BASE)
    if type(info) == "string":
        lx.kill(pid, 127)
        return info
    let entry = info.entry
    let ibase = 0
    if info.interp != nil:
        let idata = nil
        try:
            idata = read_file(info.interp)
        catch e:
            lx.kill(pid, 127)
            return "cannot read the interpreter " .. info.interp
        let ii = load_elf(pid, idata, INTERP_BASE)
        if type(ii) == "string":
            lx.kill(pid, 127)
            return ii
        entry = ii.entry
        ibase = ii.base
    let g = Guest(pid, client)
    g.exe = path
    g.brk = info.top + 0x100000
    g.brk_end = g.brk
    lx.map(pid, STACK_TOP - STACK_SIZE, STACK_SIZE, 3)
    let sp = build_stack(pid, argv, envp, info, ibase)
    if sp == nil:
        lx.kill(pid, 127)
        return "cannot build the stack"
    guests[pid] = g
    let slash = last_slash(path)
    g.cwd = path.slice(0, slash) if slash > 0 else "/"
    lx.start(pid, entry, sp)
    return [pid]

func last_slash(p):
    let i = len(p) - 1
    while i >= 0:
        if p[i] == 47:
            return i
        i -= 1
    return -1

# ---- system calls ----
func out_console(g, fd, b):
    io.write(sslcore.to_text(b))
    io.flush()

func sys_write(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    let n = a[2]
    if n < 0:
        return -EINVAL
    let b = rd(g, a[1], n)
    if b == nil:
        return -EFAULT
    return do_write(g, f, b)

func do_write(g, f, b):
    if f.kind == "console":
        out_console(g, f.fd, b)
        return len(b)
    if f.kind == "file":
        if not f.writable:
            return -EBADF
        try:
            if f.append:
                f.pos = fs.stat(f.path).size
            fs.write_bytes(f.path, b, f.pos, false)
        catch e:
            return -errno_of(e.kind)
        f.pos += len(b)
        return len(b)
    if f.kind == "null":
        return len(b)
    return -EBADF

func sys_writev(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    let total = 0
    for i in range(a[2]):
        let iov = rd(g, a[1] + i * 16, 16)
        if iov == nil:
            return -EFAULT
        let n = u64(iov, 8)
        if n == 0:
            continue
        let b = rd(g, u64(iov, 0), n)
        if b == nil:
            return -EFAULT
        let r = do_write(g, f, b)
        if r < 0:
            return r if total == 0 else total
        total += r
    return total

func do_read(g, f, n, off):
    if f.kind == "stdin":
        return sslcore.concat([[]])
    if f.kind == "null":
        return sslcore.concat([[]])
    if f.kind == "zero":
        let z = []
        for i in range(n):
            z.append(0)
        return sslcore.concat([z])
    if f.kind == "random":
        return sslcore.random(n)
    if f.kind != "file":
        return -EBADF
    if not f.readable:
        return -EBADF
    try:
        let size = fs.stat(f.path).size
        let at = f.pos if off < 0 else off
        let want = imin(n, size - at)
        if want <= 0:
            return sslcore.concat([[]])
        return fs.read_bytes(f.path, at, want)
    catch e:
        return -errno_of(e.kind)

func sys_read(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    if f.kind == "dir":
        return -EISDIR
    let r = do_read(g, f, a[2], -1)
    if type(r) == "int":
        return r
    if f.kind == "file":
        f.pos += len(r)
    let e = wr(g, a[1], r)
    return e if e < 0 else len(r)

func sys_pread(g, a):
    let f = g.fds[a[0]]
    if f == nil or f.kind != "file":
        return -EBADF
    let r = do_read(g, f, a[2], a[3])
    if type(r) == "int":
        return r
    let e = wr(g, a[1], r)
    return e if e < 0 else len(r)

func sys_pwrite(g, a):
    let f = g.fds[a[0]]
    if f == nil or f.kind != "file" or not f.writable:
        return -EBADF
    let b = rd(g, a[1], a[2])
    if b == nil:
        return -EFAULT
    try:
        fs.write_bytes(f.path, b, a[3], false)
    catch e:
        return -errno_of(e.kind)
    return len(b)

func sys_lseek(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    if f.kind != "file" and f.kind != "dir":
        return -ESPIPE
    let base = 0
    if a[2] == 1:
        base = f.pos
    elif a[2] == 2:
        try:
            base = fs.stat(f.path).size
        catch e:
            return -errno_of(e.kind)
    elif a[2] != 0:
        return -EINVAL
    let p = base + a[1]
    if p < 0:
        return -EINVAL
    f.pos = p
    return p

func do_open(g, path, flags, mode):
    let p = abspath(g, path)
    if p == "/dev/null":
        return g.alloc_fd({kind: "null"})
    if p == "/dev/zero":
        return g.alloc_fd({kind: "zero"})
    if p == "/dev/urandom" or p == "/dev/random":
        return g.alloc_fd({kind: "random"})
    if p == "/dev/tty" or p == "/dev/console":
        return g.alloc_fd({kind: "console", fd: 1})
    let acc = flags & 3
    let st = nil
    try:
        if fs.exists(p):
            st = fs.stat(p)
    catch e:
        return -errno_of(e.kind)
    if st == nil:
        if (flags & 0o100) == 0:
            return -ENOENT
        try:
            fs.write_bytes(p, sslcore.concat([[]]), 0, true)
        catch e:
            return -errno_of(e.kind)
        return g.alloc_fd({kind: "file", path: p, pos: 0, readable: acc != 1, writable: acc != 0, append: (flags & 0o2000) != 0})
    if st.kind == "dir":
        if acc != 0:
            return -EISDIR
        return g.alloc_fd({kind: "dir", path: p, pos: 0, names: nil})
    if (flags & 0o200000) != 0:
        return -ENOTDIR
    if (flags & 0o100) != 0 and (flags & 0o200) != 0:
        return -EEXIST
    if (flags & 0o1000) != 0 and acc != 0:
        try:
            fs.write_bytes(p, sslcore.concat([[]]), 0, true)
        catch e:
            return -errno_of(e.kind)
    return g.alloc_fd({kind: "file", path: p, pos: 0, readable: acc != 1, writable: acc != 0, append: (flags & 0o2000) != 0})

func sys_open(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    return do_open(g, path, a[1], a[2])

func sys_openat(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    if a[0] != AT_FDCWD and not path.starts_with("/"):
        let d = g.fds[a[0]]
        if d == nil or d.kind != "dir":
            return -EBADF
        path = d.path .. "/" .. path
    return do_open(g, path, a[2], a[3])

func sys_close(g, a):
    if g.fds[a[0]] == nil:
        return -EBADF
    g.fds[a[0]] = nil
    return 0

# struct stat (144 bytes)
func fill_stat(kind, size, mtime, ino):
    let b = []
    for i in range(144):
        b.append(0)
    let mode = 0o40755 if kind == "dir" else (0o120777 if kind == "symlink" else 0o100644)
    put64(b, 0, 1)
    put64(b, 8, ino)
    put64(b, 16, 2 if kind == "dir" else 1)
    put32(b, 24, mode)
    put64(b, 48, size)
    put64(b, 56, 4096)
    put64(b, 64, (size + 511) // 512)
    put64(b, 72, mtime)
    put64(b, 88, mtime)
    put64(b, 104, mtime)
    return sslcore.concat([b])

func stat_path(g, p, buf):
    let ap = abspath(g, p)
    if ap == "/dev/null" or ap == "/dev/zero" or ap == "/dev/urandom" or ap == "/dev/tty":
        let b = fill_stat("file", 0, 0, 3)
        b[24] = 0o20666 & 255
        b[25] = (0o20666 >> 8) & 255
        return wr(g, buf, b)
    try:
        let st = fs.stat(ap)
        return wr(g, buf, fill_stat(st.kind, st.size, st.mtime, 1000 + len(ap)))
    catch e:
        return -errno_of(e.kind)

func sys_stat(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    return stat_path(g, path, a[1])

func sys_fstat(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    if f.kind == "console" or f.kind == "stdin":
        let b = fill_stat("file", 0, 0, 5)
        let m = 0o20620
        b[24] = m & 255
        b[25] = (m >> 8) & 255
        return wr(g, a[1], b)
    if f.kind == "null" or f.kind == "zero" or f.kind == "random":
        let b = fill_stat("file", 0, 0, 3)
        b[24] = 0o20666 & 255
        b[25] = (0o20666 >> 8) & 255
        return wr(g, a[1], b)
    return stat_path(g, f.path, a[1])

func sys_newfstatat(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    if path == "" and (a[3] & 0x1000) != 0:
        return sys_fstat(g, [a[0], a[2]])
    if a[0] != AT_FDCWD and not path.starts_with("/"):
        let d = g.fds[a[0]]
        if d == nil or d.kind != "dir":
            return -EBADF
        path = d.path .. "/" .. path
    return stat_path(g, path, a[2])

func sys_access(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    try:
        return 0 if fs.exists(abspath(g, path)) else -ENOENT
    catch e:
        return -errno_of(e.kind)

func sys_faccessat(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    try:
        return 0 if fs.exists(abspath(g, path)) else -ENOENT
    catch e:
        return -errno_of(e.kind)

func sys_getdents64(g, a):
    let f = g.fds[a[0]]
    if f == nil or f.kind != "dir":
        return -EBADF
    if f.names == nil:
        let l = []
        try:
            for e in fs.listdir(f.path):
                l.append(e)
        catch e:
            return -errno_of(e.kind)
        f.names = [{kind: "dir", name: "."}, {kind: "dir", name: ".."}]
        for e in l:
            f.names.append(e)
    let out = []
    let used = 0
    while f.pos < len(f.names):
        let e = f.names[f.pos]
        let nm = sslcore.from_str(e.name)
        let reclen = (19 + len(nm) + 1 + 7) & ~7
        if used + reclen > a[2]:
            break
        let rec = []
        for i in range(reclen):
            rec.append(0)
        put64(rec, 0, 2000 + f.pos)
        put64(rec, 8, f.pos + 1)
        put16(rec, 16, reclen)
        rec[18] = 4 if e.kind == "dir" else 8
        for i in range(len(nm)):
            rec[19 + i] = nm[i]
        out.append(rec)
        used += reclen
        f.pos += 1
    if used == 0:
        return 0
    let r = wr(g, a[1], sslcore.concat(out))
    return r if r < 0 else used

func sys_getcwd(g, a):
    let b = sslcore.from_str(g.cwd)
    if len(b) + 1 > a[1]:
        return -ERANGE
    let r = wr(g, a[0], sslcore.concat([b, [0]]))
    return r if r < 0 else len(b) + 1

func sys_chdir(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    let p = abspath(g, path)
    try:
        if fs.stat(p).kind != "dir":
            return -ENOTDIR
    catch e:
        return -errno_of(e.kind)
    g.cwd = p
    return 0

func sys_mkdir(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    try:
        fs.mkdir(abspath(g, path))
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_unlink(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    try:
        fs.unlink(abspath(g, path))
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_rmdir(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    try:
        fs.rmdir(abspath(g, path))
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_rename(g, a):
    let p1 = cstr(g, a[0])
    let p2 = cstr(g, a[1])
    if p1 == nil or p2 == nil:
        return -EFAULT
    try:
        fs.rename(abspath(g, p1), abspath(g, p2))
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_ftruncate(g, a):
    let f = g.fds[a[0]]
    if f == nil or f.kind != "file":
        return -EBADF
    try:
        fs.truncate(f.path, a[1])
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_dup(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    return g.alloc_fd(f)

func sys_dup2(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    if a[0] != a[1]:
        g.fds[a[1]] = f
    return a[1]

func sys_fcntl(g, a):
    if g.fds[a[0]] == nil:
        return -EBADF
    if a[1] == 0 or a[1] == 1030:       # F_DUPFD, F_DUPFD_CLOEXEC
        return g.alloc_fd(g.fds[a[0]], a[2])
    return 0

func sys_ioctl(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    return -ENOTTY

# memory
func sys_brk(g, a):
    let want = a[0]
    if want == 0 or want < g.brk - (256 << 20) or want > g.brk + (256 << 20):
        return g.brk
    let top = align_up(want)
    if top > g.brk_end:
        if lx.map(g.pid, g.brk_end, top - g.brk_end, 3) != 0:
            return g.brk
        g.brk_end = top
    elif top < g.brk_end and want >= g.brk - (256 << 20):
        # (the program keeps what it wrote below the new break; pages above it go)
        pass
    g.brk = want
    return g.brk

func sys_mmap(g, a):
    let addr = a[0]
    let length = a[1]
    let prot = a[2]
    let flags = a[3]
    let fd = a[4]
    let off = a[5]
    if length <= 0:
        return -EINVAL
    let n = align_up(length)
    let fixed = (flags & 0x10) != 0
    if fixed:
        if (addr & 4095) != 0 or addr < USER_BASE:
            return -EINVAL
    else:
        addr = g.mmap_next
        g.mmap_next += n + 4096
    let f = nil
    if (flags & 0x20) == 0:
        f = g.fds[fd]
        if f == nil or f.kind != "file":
            return -EBADF
    if lx.map(g.pid, addr, n, 3 if f != nil else (3 if (prot & 2) != 0 else 1)) != 0:
        return -ENOMEM
    if f != nil:
        let data = do_read(g, f, length, off)
        if type(data) == "int":
            return data
        if len(data) > 0 and lx.write(g.pid, addr, data) != 0:
            return -EFAULT
        if (prot & 2) == 0:
            lx.protect(g.pid, addr, n, 1)
    return addr

func sys_munmap(g, a):
    if (a[0] & 4095) != 0:
        return -EINVAL
    lx.unmap(g.pid, a[0], a[1])
    return 0

func sys_mprotect(g, a):
    lx.protect(g.pid, a[0] & ~4095, a[1], a[2])
    return 0

func sys_mremap(g, a):
    # grow by mapping a new region and copying (the old one is released)
    let old = a[0]
    let oldlen = align_up(a[1])
    let newlen = align_up(a[2])
    if newlen <= oldlen:
        if newlen < oldlen:
            lx.unmap(g.pid, old + newlen, oldlen - newlen)
        return old
    if (a[3] & 1) == 0:
        return -ENOMEM
    let na = g.mmap_next
    g.mmap_next += newlen + 4096
    if lx.map(g.pid, na, newlen, 3) != 0:
        return -ENOMEM
    let data = lx.read(g.pid, old, oldlen)
    if data == nil or lx.write(g.pid, na, data) != 0:
        return -EFAULT
    lx.unmap(g.pid, old, oldlen)
    return na

# process, time, misc
func sys_exit(g, a):
    finish(g, a[0] & 255)
    return nil

func finish(g, code):
    lx.kill(g.pid, code)
    guests[g.pid] = nil
    if g.client != 0:
        ipc.send(g.client, "exit\t" .. to_string(g.pid) .. "\t" .. to_string(code))

func sys_uname(g, a):
    let b = []
    for i in range(65 * 6):
        b.append(0)
    putstr(b, 0, "Linux")
    putstr(b, 65, "sprintos")
    putstr(b, 130, "6.1.0-sprintos")
    putstr(b, 195, "#1 SprintOS")
    putstr(b, 260, "x86_64")
    putstr(b, 325, "(none)")
    return wr(g, a[0], sslcore.concat([b]))

func sys_arch_prctl(g, a):
    if a[0] == 0x1002:
        lx.setfs(g.pid, a[1])
        return 0
    return -EINVAL

func sys_getpid(g, a):
    return g.pid

func sys_zero(g, a):
    return 0

func sys_enosys(g, a):
    return -ENOSYS

func sys_getuid(g, a):
    return 0

func now_us():
    return psys.ms() * 1000

func sys_clock_gettime(g, a):
    let us = now_us()
    let b = []
    for i in range(16):
        b.append(0)
    put64(b, 0, us // 1000000)
    put64(b, 8, (us % 1000000) * 1000)
    return wr(g, a[1], sslcore.concat([b]))

func sys_gettimeofday(g, a):
    let us = now_us()
    let b = []
    for i in range(16):
        b.append(0)
    put64(b, 0, us // 1000000)
    put64(b, 8, us % 1000000)
    if a[0] != 0:
        return wr(g, a[0], sslcore.concat([b]))
    return 0

func sys_nanosleep(g, a):
    let ts = rd(g, a[0], 16)
    if ts == nil:
        return -EFAULT
    psys.sleep_ms(u64(ts, 0) * 1000 + u64(ts, 8) // 1000000)
    return 0

func sys_clock_nanosleep(g, a):
    let ts = rd(g, a[2], 16)
    if ts == nil:
        return -EFAULT
    psys.sleep_ms(u64(ts, 0) * 1000 + u64(ts, 8) // 1000000)
    return 0

func sys_getrandom(g, a):
    let n = imin(a[1], 1 << 20)
    let r = wr(g, a[0], sslcore.random(n))
    return r if r < 0 else n

func sys_prlimit64(g, a):
    if a[3] != 0:
        let b = []
        for i in range(16):
            b.append(255)
        if a[1] == 3:         # RLIMIT_STACK: 8 MiB
            put64(b, 0, STACK_SIZE)
        elif a[1] == 7:       # RLIMIT_NOFILE
            put64(b, 0, 1024)
            put64(b, 8, 4096)
        return wr(g, a[3], sslcore.concat([b]))
    return 0

func sys_readlink(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    if path == "/proc/self/exe":
        let b = sslcore.from_str(g.exe)
        let r = wr(g, a[1], b.slice(0, imin(len(b), a[2])))
        return r if r < 0 else imin(len(b), a[2])
    return -EINVAL

func sys_sysinfo(g, a):
    let b = []
    for i in range(112):
        b.append(0)
    put64(b, 0, psys.ms() // 1000)
    put64(b, 32, 256 << 20)
    put64(b, 40, 128 << 20)
    put32(b, 104, 1)
    return wr(g, a[0], sslcore.concat([b]))

func sys_futex(g, a):
    let op = a[1] & 127
    if op == 0:           # FUTEX_WAIT in a single thread: the value would never change
        return -EAGAIN
    return 0

func setup():
    table[0] = sys_read
    table[1] = sys_write
    table[2] = sys_open
    table[3] = sys_close
    table[4] = sys_stat
    table[5] = sys_fstat
    table[6] = sys_stat
    table[8] = sys_lseek
    table[9] = sys_mmap
    table[10] = sys_mprotect
    table[11] = sys_munmap
    table[12] = sys_brk
    table[13] = sys_zero
    table[14] = sys_zero
    table[16] = sys_ioctl
    table[17] = sys_pread
    table[18] = sys_pwrite
    table[20] = sys_writev
    table[21] = sys_access
    table[25] = sys_mremap
    table[28] = sys_zero
    table[32] = sys_dup
    table[33] = sys_dup2
    table[35] = sys_nanosleep
    table[39] = sys_getpid
    table[60] = sys_exit
    table[63] = sys_uname
    table[72] = sys_fcntl
    table[77] = sys_ftruncate
    table[79] = sys_getcwd
    table[80] = sys_chdir
    table[82] = sys_rename
    table[83] = sys_mkdir
    table[84] = sys_rmdir
    table[87] = sys_unlink
    table[89] = sys_readlink
    table[96] = sys_gettimeofday
    table[99] = sys_sysinfo
    table[102] = sys_getuid
    table[104] = sys_getuid
    table[107] = sys_getuid
    table[108] = sys_getuid
    table[110] = sys_getpid
    table[111] = sys_getpid
    table[131] = sys_zero
    table[158] = sys_arch_prctl
    table[186] = sys_getpid
    table[202] = sys_futex
    table[217] = sys_getdents64
    table[218] = sys_getpid
    table[228] = sys_clock_gettime
    table[230] = sys_clock_nanosleep
    table[231] = sys_exit
    table[257] = sys_openat
    table[262] = sys_newfstatat
    table[269] = sys_faccessat
    table[273] = sys_zero
    table[302] = sys_prlimit64
    table[318] = sys_getrandom

# one forwarded system call of guest `g`
func serve_call(g, q):
    let nr = to_int(q[0])
    let a = []
    for i in range(1, 7):
        a.append(to_int(q[i]))
    g.calls += 1
    let f = table[nr]
    let r = nil
    if f == nil:
        if verbose:
            log("pid " .. to_string(g.pid) .. ": unimplemented system call " .. to_string(nr))
        r = -ENOSYS
    else:
        try:
            r = f(g, a)
        catch e:
            log("pid " .. to_string(g.pid) .. ": system call " .. to_string(nr) .. " failed inside linuxd: " .. to_string(e))
            r = -5
    if r != nil:
        lx.reply(g.pid, r)

func serve_request(src, text):
    let q = text.split("\t")
    if q[0] == "run":
        let argv = q[2].split("\x1f") if len(q) > 2 and q[2] != "" else [q[1]]
        let envp = q[3].split("\x1f") if len(q) > 3 and q[3] != "" else []
        let r = start_program(src, q[1], argv, envp)
        if type(r) == "string":
            ipc.send(src, "err\t" .. r)
        else:
            ipc.send(src, "ok\t" .. to_string(r[0]))
    elif q[0] == "verbose":
        verbose = true
        ipc.send(src, "ok")
    elif q[0] == "quit":
        ipc.send(src, "ok")
        return false
    return true

try:
    fs = fsclient.connect(3000)
catch e:
    log("no file system server: " .. to_string(e))
setup()
ipc.register("linux")
log("serving as \"linux\", pid " .. to_string(psys.pid()))
let running = true
while running:
    io.flush()
    let m = ipc.recv_from()
    let src = m[0]
    let text = m[1]
    let g = guests[src]
    if g != nil:
        if text.starts_with("X\t"):
            # the kernel ended it (a fault, or it was killed)
            guests[src] = nil
            if g.client != 0:
                ipc.send(g.client, "exit\t" .. to_string(src) .. "\t" .. text.slice(2))
        else:
            serve_call(g, text.split("\t"))
    elif text.starts_with("X\t"):
        pass          # a program we already finished
    else:
        running = serve_request(src, text)
log("bye")
