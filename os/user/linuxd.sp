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
let guests = {}           # pid of the first thread -> Guest (a process)
let tmap = {}             # thread id -> the Guest it belongs to
let clear_tids = {}       # thread id -> address to clear (and wake) when the thread ends
let cur_tid = 0           # the thread whose system call is being served
let futex_q = {}          # "pid:address" -> [[tid, bitset], ...]
let table = {}            # system call number -> function(g, a)
let verbose = false

func log(s):
    print("[linuxd] " .. s)
    io.flush()

# a C int argument arrives zero-extended in its 64-bit register: make it signed again
func i32(v):
    return v - 4294967296 if v >= 2147483648 and v < 4294967296 else v

func align_up(v):
    return (v + 4095) & ~4095

func imin(a, b):
    return a if a < b else b

func imax(a, b):
    return a if a > b else b

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
    let parent = 0
    let children = nil        # pid -> true: started by this program and not yet waited for
    let zombies = nil         # pid -> exit status of children that ended before the wait
    let waiting = nil         # a blocked wait4: [pid filter, status address, options, thread]
    let tids = nil            # thread id -> true
    let nthreads = 1
    let sigs = nil            # signal -> handler address (1 = ignore)
    func init(self, pid, client):
        self.pid = pid
        self.client = client
        self.children = {}
        self.zombies = {}
        self.tids = {}
        self.tids[pid] = true
        self.sigs = {}
        self.fds = {}
        self.alloc_fd({kind: "stdin"})
        self.alloc_fd({kind: "console", fd: 1})
        self.alloc_fd({kind: "console", fd: 2})
    # put an open file description into the table (a new one starts with one reference, a shared one gets another)
    func alloc_fd(self, f, start = 0):
        let n = start
        while self.fds[n] != nil:
            n += 1
        self.fds[n] = f
        f.refs = 1 if f.refs == nil else f.refs + 1
        return n

# one reference to an open file description is gone
func fclose(f):
    f.refs -= 1
    if f.refs > 0:
        return nil
    if f.kind == "pipe":
        let p = f.pipe
        if f.end == "r":
            p.readers -= 1
        else:
            p.writers -= 1
            pipe_wake(p)

func release_fds(g):
    for fd in g.fds:
        let f = g.fds[fd]
        if f != nil:
            fclose(f)
    g.fds = {}

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

# a small cache of whole files (libraries and programs are read again and again): path -> [size, mtime, bytes]
let fcache = {}
let fcache_bytes = 0
func cache_drop(path):
    let e = fcache[path]
    if e != nil:
        fcache_bytes -= len(e[2])
        fcache[path] = nil

func cached_file(path):
    let st = fs.stat(path)
    if st.size > (8 << 20):
        return nil
    let e = fcache[path]
    if e != nil and e[0] == st.size and e[1] == st.mtime:
        return e[2]
    cache_drop(path)
    if fcache_bytes + st.size > (48 << 20):
        fcache = {}
        fcache_bytes = 0
    let data = fs.read_bytes(path)
    fcache[path] = [st.size, st.mtime, data]
    fcache_bytes += len(data)
    return data

func read_file(path):
    let d = cached_file(path)
    return d if d != nil else fs.read_bytes(path)

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
    if lx.write(pid, sp, sslcore.concat([buf])) != 0 or lx.write(pid, abase, sslcore.concat([area])) != 0:
        return nil
    return sp

# put the program at `path` into the (empty) address space of `pid` and give it its initial stack: [entry, sp] or an error string
func setup_image(pid, img, path, argv, envp, g):
    let info = load_elf(pid, img, PIE_BASE)
    if type(info) == "string":
        return info
    let entry = info.entry
    let ibase = 0
    if info.interp != nil:
        let idata = nil
        try:
            idata = read_file(info.interp)
        catch e:
            return "cannot read the interpreter " .. info.interp
        let ii = load_elf(pid, idata, INTERP_BASE)
        if type(ii) == "string":
            return ii
        entry = ii.entry
        ibase = ii.base
    g.exe = path
    g.brk = info.top + 0x100000
    g.brk_end = g.brk
    g.mmap_next = MMAP_BASE
    lx.map(pid, STACK_TOP - STACK_SIZE, STACK_SIZE, 3)
    let sp = build_stack(pid, argv, envp, info, ibase)
    if sp == nil:
        return "cannot build the stack"
    return [entry, sp]

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
    let g = Guest(pid, client)
    let r = setup_image(pid, img, path, argv, envp, g)
    if type(r) == "string":
        lx.kill(pid, 127)
        return r
    guests[pid] = g
    tmap[pid] = g
    let slash = last_slash(path)
    g.cwd = path.slice(0, slash) if slash > 0 else "/"
    lx.start(pid, r[0], r[1])
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
            cache_drop(f.path)
            fs.write_bytes(f.path, b, f.pos, false)
        catch e:
            return -errno_of(e.kind)
        f.pos += len(b)
        return len(b)
    if f.kind == "null":
        return len(b)
    if f.kind == "eventfd":
        return eventfd_write(g, f, b)
    if f.kind == "pipe" and f.end == "w":
        let p = f.pipe
        if p.readers == 0:
            return -32
        p.data.append(b)
        p.size += len(b)
        pipe_wake(p)
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
        let whole = cached_file(f.path)
        if whole != nil:
            return whole.slice(at, at + want)
        return fs.read_bytes(f.path, at, want)
    catch e:
        return -errno_of(e.kind)

func sys_read(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    if f.kind == "dir":
        return -EISDIR
    if f.kind == "eventfd":
        return eventfd_read(g, f, a[1])
    if f.kind == "pipe":
        if f.end != "r":
            return -EBADF
        let p = f.pipe
        if p.size == 0:
            if p.writers == 0:
                return 0
            p.rwait.append([g, a[1], a[2], cur_tid])
            return nil
        let chunk = pipe_take(p, imin(a[2], p.size))
        let e0 = wr(g, a[1], chunk)
        return e0 if e0 < 0 else len(chunk)
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
        cache_drop(f.path)
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
    if verbose == "paths":
        log("open " .. p .. " by " .. to_string(g.pid))
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
    if i32(a[0]) != AT_FDCWD and not path.starts_with("/"):
        let d = g.fds[i32(a[0])]
        if d == nil or d.kind != "dir":
            return -EBADF
        path = d.path .. "/" .. path
    return do_open(g, path, a[2], a[3])

func sys_close(g, a):
    let f = g.fds[a[0]]
    if f == nil:
        return -EBADF
    g.fds[a[0]] = nil
    fclose(f)
    return 0

# a stable inode number for a path (the file system server does not report one): FNV-1a of the path
func path_ino(p):
    let h = 2166136261
    let b = sslcore.from_str(p)
    for x in b:
        h = ((h ^ x) * 16777619) & 0xFFFFFFFF
    return h + 2

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
        return wr(g, buf, fill_stat(st.kind, st.size, st.mtime, path_ino(ap)))
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
    if f.kind == "pipe" or f.kind == "eventfd" or f.kind == "epoll" or f.kind == "sock":
        let b = fill_stat("file", 0, 0, 7)
        let m = 0o140777 if f.kind == "sock" else (0o10600 if f.kind == "pipe" else 0o600)
        b[24] = m & 255
        b[25] = (m >> 8) & 255
        return wr(g, a[1], b)
    return stat_path(g, f.path, a[1])

func sys_newfstatat(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    if path == "" and (a[3] & 0x1000) != 0:
        return sys_fstat(g, [a[0], a[2]])
    if i32(a[0]) != AT_FDCWD and not path.starts_with("/"):
        let d = g.fds[i32(a[0])]
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
        let old = g.fds[a[1]]
        g.fds[a[1]] = f
        f.refs += 1
        if old != nil:
            fclose(old)
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
        f = g.fds[i32(fd)]
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
    finish(g, a[0] & 255, (a[0] & 255) << 8)
    return nil

# the program is gone: free its descriptors, tell its parent (or whoever started it)
func finish(g, code, status):
    lx.kill(g.pid, code)
    ended(g, status)

func ended(g, status):
    if verbose:
        log("pid " .. to_string(g.pid) .. " ended at " .. to_string(psys.ms()) .. " after " .. to_string(g.calls) .. " calls")
    guests[g.pid] = nil
    for t in g.tids:
        if t != g.pid:
            lx.kill(t, 0)
        tmap[t] = nil
        clear_tids[t] = nil
    lx.kill(g.pid, 0)
    g.tids = {}
    release_fds(g)
    for c in g.children:
        let ch = guests[c]
        if ch != nil:
            ch.parent = 0
    let par = guests[g.parent] if g.parent != 0 else nil
    if par != nil:
        if par.waiting != nil and (par.waiting[0] == -1 or par.waiting[0] == g.pid):
            let w = par.waiting
            par.waiting = nil
            par.children[g.pid] = nil
            if w[1] != 0:
                let sb = []
                for i in range(4):
                    sb.append((status >> (8 * i)) & 255)
                wr(par, w[1], sslcore.concat([sb]))
            lx.reply(w[3], g.pid)
        else:
            par.zombies[g.pid] = status
    if g.client != 0:
        ipc.send(g.client, "exit\t" .. to_string(g.pid) .. "\t" .. to_string(status >> 8 if status > 255 else status))

# ---- pipes ----
func new_pipe():
    return {data: nil, size: 0, readers: 1, writers: 1, rwait: []}

func pipe_wake(p):
    # serve the readers that are waiting
    while len(p.rwait) > 0:
        let w = p.rwait[0]
        if p.size == 0 and p.writers > 0:
            return nil
        p.rwait.remove_at(0)
        let n = imin(w[2], p.size)
        let chunk = sslcore.concat([])
        if n > 0:
            chunk = pipe_take(p, n)
        let r = wr(w[0], w[1], chunk) if n > 0 else 0
        lx.reply(w[3], r if r < 0 else n)

func pipe_take(p, n):
    let all = sslcore.concat(p.data)
    let out = all.slice(0, n)
    let rest = all.slice(n)
    p.data = [rest] if len(rest) > 0 else []
    p.size = len(rest)
    return out

func sys_pipe(g, a):
    let p = new_pipe()
    p.data = []
    let r = g.alloc_fd({kind: "pipe", pipe: p, end: "r"})
    let w = g.alloc_fd({kind: "pipe", pipe: p, end: "w"})
    let b = []
    for i in range(8):
        b.append(0)
    put32(b, 0, r)
    put32(b, 4, w)
    return wr(g, a[0], sslcore.concat([b]))

# ---- processes ----
func sys_getppid(g, a):
    return g.parent if g.parent != 0 else 1

func do_fork(g, sp, tls):
    let pid = lx.fork(cur_tid)
    if pid < 0:
        return -ENOMEM
    let c = Guest(pid, 0)
    release_fds(c)
    c.parent = g.pid
    c.cwd = g.cwd
    c.brk = g.brk
    c.brk_end = g.brk_end
    c.mmap_next = g.mmap_next
    c.exe = g.exe
    for fd in g.fds:
        let f = g.fds[fd]
        if f != nil:
            c.fds[fd] = f
            f.refs += 1
    guests[pid] = c
    tmap[pid] = c
    g.children[pid] = true
    if sp != 0:
        lx.setsp(pid, sp)
    if tls != 0:
        lx.setfs(pid, tls)
    lx.resume(pid)
    return pid

func sys_fork(g, a):
    return do_fork(g, 0, 0)

func sys_clone(g, a):
    let flags = a[0]
    if (flags & 0x10000) == 0:         # not a thread: a process (a plain fork, or posix_spawn's vfork-style clone on its own stack)
        return do_fork(g, a[1], a[4] if (flags & 0x80000) != 0 else 0)
    let tid = lx.clone(cur_tid, a[1])
    if tid < 0:
        return -ENOMEM
    tmap[tid] = g
    g.tids[tid] = true
    g.nthreads += 1
    if (flags & 0x80000) != 0:         # CLONE_SETTLS
        lx.setfs(tid, a[4])
    let idb = []
    for i in range(4):
        idb.append((tid >> (8 * i)) & 255)
    if (flags & 0x100000) != 0:        # CLONE_PARENT_SETTID
        wr(g, a[2], sslcore.concat([idb]))
    if (flags & 0x1000000) != 0:       # CLONE_CHILD_SETTID
        wr(g, a[3], sslcore.concat([idb]))
    if (flags & 0x200000) != 0:        # CLONE_CHILD_CLEARTID
        clear_tids[tid] = a[3]
    lx.resume(tid)
    return tid

func sys_gettid(g, a):
    return cur_tid

func sys_set_tid_address(g, a):
    clear_tids[cur_tid] = a[0]
    return cur_tid

func sys_exit_thread(g, a):
    # a thread of a process with other threads ends alone; the last one (or the leader) ends the process
    if g.nthreads > 1 and cur_tid != g.pid:
        let addr = clear_tids[cur_tid]
        if addr != nil and addr != 0:
            wr(g, addr, sslcore.concat([[0, 0, 0, 0]]))
            futex_wake(to_string(g.pid) .. ":" .. to_string(addr), 1)
        clear_tids[cur_tid] = nil
        tmap[cur_tid] = nil
        g.tids[cur_tid] = nil
        g.nthreads -= 1
        lx.kill(cur_tid, 0)
        return nil
    finish(g, a[0] & 255, (a[0] & 255) << 8)
    return nil

# rt_sigaction(sig, act, oldact, size): the handler is remembered (it cannot be delivered yet); SIG_IGN is honoured by kill()
func sys_sigaction(g, a):
    if a[2] != 0:
        wr(g, a[2], sslcore.concat([[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]))
    if a[1] != 0:
        let act = rd(g, a[1], 8)
        if act == nil:
            return -EFAULT
        g.sigs[a[0]] = u64(act, 0)
    return 0

func sys_sched_getaffinity(g, a):
    wr(g, a[2], sslcore.concat([[1, 0, 0, 0, 0, 0, 0, 0]]))
    return 8

func sys_wait4(g, a):
    let want = i32(a[0])
    let sp = a[1]
    for z in g.zombies:
        if want == -1 or want == z:
            let st = g.zombies[z]
            g.zombies[z] = nil
            g.children[z] = nil
            if sp != 0:
                let sb = []
                for i in range(4):
                    sb.append((st >> (8 * i)) & 255)
                wr(g, sp, sslcore.concat([sb]))
            return z
    if len(g.children) == 0:
        return -ECHILD
    if (a[2] & 1) != 0:       # WNOHANG
        return 0
    g.waiting = [want, sp, a[2], cur_tid]
    return nil

func deliver_signal(t, sig):
    if sig == 0 or sig == 17 or sig == 28 or sig == 23 or sig == 18 or sig == 20:
        return 0
    let h = t.sigs[sig]
    if h == 1:
        return 0
    if h != nil and h > 1:
        log("signal " .. to_string(sig) .. " for pid " .. to_string(t.pid) .. " has a handler; handlers are not delivered yet")
        return 0
    lx.kill(t.pid, 128 + sig)
    ended(t, sig)
    return 0

func sys_kill(g, a):
    let t = guests[i32(a[0])]
    if t == nil:
        return -3
    return deliver_signal(t, a[1])

func sys_tgkill(g, a):          # tgkill(tgid, tid, sig)
    let t = guests[a[0]]
    if t == nil:
        return -3
    return deliver_signal(t, a[2])

func sys_tkill(g, a):
    let t = tmap[a[0]]
    if t == nil:
        return -3
    return deliver_signal(t, a[1])

# the strings of a NULL-terminated array of C string pointers
func string_vec(g, addr):
    let out = []
    if addr == 0:
        return out
    for i in range(4096):
        let p = rd(g, addr + 8 * i, 8)
        if p == nil:
            return nil
        let v = u64(p, 0)
        if v == 0:
            return out
        let s = cstr(g, v)
        if s == nil:
            return nil
        out.append(s)
    return nil

func sys_execve(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    let argv = string_vec(g, a[1])
    let envp = string_vec(g, a[2])
    if argv == nil or envp == nil:
        return -EFAULT
    let p = abspath(g, path)
    let img = nil
    try:
        img = read_file(p)
    catch e:
        return -errno_of(e.kind)
    # a script: #!interpreter [argument]
    if len(img) > 2 and img[0] == 35 and img[1] == 33:
        let eol = 0
        while eol < len(img) and img[eol] != 10:
            eol += 1
        let line = sslcore.to_text(img.slice(2, eol)).trim().split(" ")
        let nargv = [line[0]]
        if len(line) > 1 and line[1] != "":
            nargv.append(line[1])
        nargv.append(p)
        for i in range(1, len(argv)):
            nargv.append(argv[i])
        argv = nargv
        try:
            img = read_file(line[0])
        catch e:
            return -errno_of(e.kind)
        p = line[0]
    let t0 = psys.ms()
    lx.reset(g.pid)
    let r = setup_image(g.pid, img, p, argv, envp, g)
    if verbose:
        log("exec " .. p .. " took " .. to_string(psys.ms() - t0) .. " ms at " .. to_string(psys.ms()))
    if type(r) == "string":
        log("exec " .. p .. ": " .. r)
        finish(g, 127, 127 << 8)
        return nil
    lx.setfs(g.pid, 0)
    lx.start(g.pid, r[0], r[1])
    return nil

# a program that is told to sleep: it stays blocked until its time has come
# timers: [deadline ms, thread, result, futex key (or nil)]; when one fires the thread's blocked system call returns `result`
let sleepers = []
func sleep_for(g, ms):
    sleepers.append([psys.ms() + ms, cur_tid, 0, nil])
    return nil

func wake_sleepers():
    let now = psys.ms()
    let keep = []
    for s in sleepers:
        if s[0] <= now:
            if tmap[s[1]] != nil:
                if s[3] != nil:
                    futex_drop(s[3], s[1])
                lx.reply(s[1], s[2])
        else:
            keep.append(s)
    sleepers = keep

func next_wake():
    let best = 0
    for s in sleepers:
        let d = imax(1, s[0] - psys.ms())
        if best == 0 or d < best:
            best = d
    return best

# ---- futexes: a thread that waits stays blocked until another one wakes it (or the timeout) ----
func futex_drop(key, tid):
    let l = futex_q[key]
    if l == nil:
        return nil
    let keep = []
    for w in l:
        if w[0] != tid:
            keep.append(w)
    futex_q[key] = keep

func futex_wake(key, n):
    let l = futex_q[key]
    let woken = 0
    if l == nil:
        return 0
    while len(l) > 0 and woken < n:
        let w = l.remove_at(0)
        lx.reply(w[0], 0)
        woken += 1
        # its timeout (if any) is cancelled
        let keep = []
        for s in sleepers:
            if not (s[1] == w[0] and s[3] != nil):
                keep.append(s)
        sleepers = keep
    return woken

func read_i32(g, addr):
    let b = rd(g, addr, 4)
    if b == nil:
        return nil
    let v = u32(b, 0)
    return v - 4294967296 if v >= 2147483648 else v

func sys_futex(g, a):
    let op = a[1] & 127
    let key = to_string(g.pid) .. ":" .. to_string(a[0])
    if op == 0 or op == 9:         # FUTEX_WAIT, FUTEX_WAIT_BITSET
        let cur = read_i32(g, a[0])
        if cur == nil:
            return -EFAULT
        let want = a[2]
        if want >= 2147483648:
            want -= 4294967296
        if cur != want:
            return -EAGAIN
        if futex_q[key] == nil:
            futex_q[key] = []
        futex_q[key].append([cur_tid, 0xffffffff])
        if a[3] != 0:
            let ts = rd(g, a[3], 16)
            if ts == nil:
                return -EFAULT
            let ms = u64(ts, 0) * 1000 + u64(ts, 8) // 1000000
            if op == 9:
                ms = imax(0, ms - psys.ms())
            sleepers.append([psys.ms() + ms, cur_tid, -110, key])
        return nil
    if op == 1 or op == 10:        # FUTEX_WAKE, FUTEX_WAKE_BITSET
        return futex_wake(key, a[2])
    if op == 3 or op == 4:         # FUTEX_REQUEUE, FUTEX_CMP_REQUEUE
        if op == 4:
            let cur = read_i32(g, a[0])
            let want = a[5]
            if want >= 2147483648:
                want -= 4294967296
            if cur != want:
                return -EAGAIN
        let key2 = to_string(g.pid) .. ":" .. to_string(a[4])
        let n = futex_wake(key, a[2])
        let l = futex_q[key]
        if l != nil:
            let moved = 0
            while len(l) > 0 and moved < a[3]:
                if futex_q[key2] == nil:
                    futex_q[key2] = []
                futex_q[key2].append(l.remove_at(0))
                moved += 1
            n += moved
        return n
    if op == 5:                    # FUTEX_WAKE_OP
        let key2 = to_string(g.pid) .. ":" .. to_string(a[4])
        let v3 = a[5]
        let wop = (v3 >> 28) & 15
        let cmp = (v3 >> 24) & 15
        let oparg = (v3 >> 12) & 0xfff
        let cmparg = v3 & 0xfff
        if oparg >= 2048:
            oparg -= 4096
        if cmparg >= 2048:
            cmparg -= 4096
        if (wop & 8) != 0:
            oparg = 1 << oparg
            wop = wop & 7
        let old = read_i32(g, a[4])
        if old == nil:
            return -EFAULT
        let nv = oparg
        if wop == 1:
            nv = old + oparg
        elif wop == 2:
            nv = old | oparg
        elif wop == 3:
            nv = old & ~oparg
        elif wop == 4:
            nv = old ^ oparg
        let nb = []
        for i in range(4):
            nb.append((nv >> (8 * i)) & 255)
        wr(g, a[4], sslcore.concat([nb]))
        let n = futex_wake(key, a[2])
        let hit = false
        if cmp == 0:
            hit = old == cmparg
        elif cmp == 1:
            hit = old != cmparg
        elif cmp == 2:
            hit = old < cmparg
        elif cmp == 3:
            hit = old <= cmparg
        elif cmp == 4:
            hit = old > cmparg
        elif cmp == 5:
            hit = old >= cmparg
        if hit:
            n += futex_wake(key2, a[3])
        return n
    return -ENOSYS

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
    return sleep_for(g, u64(ts, 0) * 1000 + u64(ts, 8) // 1000000)

func sys_clock_nanosleep(g, a):
    let ts = rd(g, a[2], 16)
    if ts == nil:
        return -EFAULT
    let ms = u64(ts, 0) * 1000 + u64(ts, 8) // 1000000
    if (a[1] & 1) != 0:           # TIMER_ABSTIME
        ms = imax(0, ms - psys.ms())
    return sleep_for(g, ms)

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


# ================= more of the system call table (after C-OS's cos_linux.c) =================

# a path argument relative to a directory descriptor
func at_path(g, dirfd0, path):
    let dirfd = i32(dirfd0)
    if path.starts_with("/") or dirfd == AT_FDCWD:
        return abspath(g, path)
    let d = g.fds[dirfd]
    if d == nil or d.kind != "dir":
        return nil
    return norm(d.path .. "/" .. path)

func sys_readv(g, a):
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
        let r = sys_read(g, [a[0], u64(iov, 0), n])
        if r == nil:
            return nil if total == 0 else total
        if r < 0:
            return r if total == 0 else total
        total += r
        if r < n:
            break
    return total

func sys_preadv(g, a):
    let f = g.fds[a[0]]
    if f == nil or f.kind != "file":
        return -EBADF
    let total = 0
    for i in range(a[2]):
        let iov = rd(g, a[1] + i * 16, 16)
        if iov == nil:
            return -EFAULT
        let n = u64(iov, 8)
        let r = sys_pread(g, [a[0], u64(iov, 0), n, a[3] + total])
        if r < 0:
            return r if total == 0 else total
        total += r
        if r < n:
            break
    return total

func sys_pwritev(g, a):
    let total = 0
    for i in range(a[2]):
        let iov = rd(g, a[1] + i * 16, 16)
        if iov == nil:
            return -EFAULT
        let r = sys_pwrite(g, [a[0], u64(iov, 0), u64(iov, 8), a[3] + total])
        if r < 0:
            return r if total == 0 else total
        total += r
    return total

func sys_creat(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    return do_open(g, path, 0o1101, a[1])

func sys_truncate(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    try:
        fs.truncate(abspath(g, path), a[1])
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_fchdir(g, a):
    let d = g.fds[a[0]]
    if d == nil or d.kind != "dir":
        return -EBADF
    g.cwd = d.path
    return 0

func sys_statfs(g, a):
    let b = []
    for i in range(120):
        b.append(0)
    try:
        let sf = fs.statfs()
        put64(b, 0, 0x53707266)
        put64(b, 8, 4096)
        put64(b, 16, sf.blocks)
        put64(b, 24, sf.free_blocks)
        put64(b, 32, sf.free_blocks)
        put64(b, 72, 255)
        put64(b, 80, 4096)
    catch e:
        return -errno_of(e.kind)
    return wr(g, a[1], sslcore.concat([b]))

func sys_mkdirat(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    let p = at_path(g, a[0], path)
    if p == nil:
        return -EBADF
    try:
        fs.mkdir(p)
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_unlinkat(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    let p = at_path(g, a[0], path)
    if p == nil:
        return -EBADF
    try:
        if (a[2] & 0x200) != 0:
            fs.rmdir(p)
        else:
            fs.unlink(p)
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_renameat(g, a):
    let p1 = cstr(g, a[1])
    let p2 = cstr(g, a[3])
    if p1 == nil or p2 == nil:
        return -EFAULT
    let x = at_path(g, a[0], p1)
    let y = at_path(g, a[2], p2)
    if x == nil or y == nil:
        return -EBADF
    try:
        fs.rename(x, y)
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_readlinkat(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    let p = at_path(g, a[0], path)
    if p == nil:
        p = abspath(g, path)
    return readlink_path(g, p, a[2], a[3])

func readlink_path(g, p, buf, size):
    if p == "/proc/self/exe":
        let b = sslcore.from_str(g.exe)
        let n = imin(len(b), size)
        let r = wr(g, buf, b.slice(0, n))
        return r if r < 0 else n
    if p == "/proc/self/cwd":
        let b = sslcore.from_str(g.cwd)
        let n = imin(len(b), size)
        let r = wr(g, buf, b.slice(0, n))
        return r if r < 0 else n
    return -EINVAL

func sys_faccessat2(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    let p = at_path(g, a[0], path)
    if p == nil:
        return -EBADF
    try:
        return 0 if fs.exists(p) else -ENOENT
    catch e:
        return -errno_of(e.kind)

func sys_dup3(g, a):
    if a[0] == a[1]:
        return -EINVAL
    return sys_dup2(g, a)

func sys_statx(g, a):
    let path = cstr(g, a[1])
    if path == nil:
        return -EFAULT
    let kind = "file"
    let size = 0
    let mtime = 0
    let special = false
    if path == "" and (a[2] & 0x1000) != 0:
        let f = g.fds[a[0]]
        if f == nil:
            return -EBADF
        if f.kind == "console" or f.kind == "stdin" or f.kind == "null" or f.kind == "zero" or f.kind == "random" or f.kind == "pipe":
            special = true
        else:
            path = f.path
    else:
        path = at_path(g, a[0], path)
        if path == nil:
            return -EBADF
    if not special:
        try:
            let st = fs.stat(path)
            kind = st.kind
            size = st.size
            mtime = st.mtime
        catch e:
            return -errno_of(e.kind)
    let b = []
    for i in range(256):
        b.append(0)
    put32(b, 0, 0xfff)
    put32(b, 4, 4096)
    put32(b, 16, 2 if kind == "dir" else 1)
    put16(b, 28, 0o20620 if special else (0o40755 if kind == "dir" else 0o100644))
    put64(b, 32, path_ino(path))
    put64(b, 40, size)
    put64(b, 48, (size + 511) // 512)
    for o in [64, 80, 96, 112]:
        put64(b, o, mtime)
    return wr(g, a[4], sslcore.concat([b]))

func sys_getrlimit(g, a):
    return sys_prlimit64(g, [0, a[0], 0, a[1]])

func sys_time(g, a):
    let t = now_us() // 1000000
    if a[0] != 0:
        let b = []
        for i in range(8):
            b.append(0)
        put64(b, 0, t)
        wr(g, a[0], sslcore.concat([b]))
    return t

func sys_times(g, a):
    if a[0] != 0:
        let b = []
        for i in range(32):
            b.append(0)
        wr(g, a[0], sslcore.concat([b]))
    return psys.ms() // 10

func sys_getrusage(g, a):
    let b = []
    for i in range(144):
        b.append(0)
    return wr(g, a[1], sslcore.concat([b]))

func sys_clock_getres(g, a):
    if a[1] != 0:
        let b = []
        for i in range(16):
            b.append(0)
        put64(b, 8, 1000000)
        return wr(g, a[1], sslcore.concat([b]))
    return 0

func sys_prctl(g, a):
    return 0

func sys_getgroups(g, a):
    return 0

func sys_umask(g, a):
    return 0o22

func sys_getcpu(g, a):
    if a[0] != 0:
        wr(g, a[0], sslcore.concat([[0, 0, 0, 0]]))
    if a[1] != 0:
        wr(g, a[1], sslcore.concat([[0, 0, 0, 0]]))
    return 0

func sys_getresuid(g, a):
    for i in range(3):
        wr(g, a[i], sslcore.concat([[0, 0, 0, 0]]))
    return 0

func sys_close_range(g, a):
    for fd in range(a[0], imin(a[1], 4096) + 1):
        let f = g.fds[fd]
        if f != nil:
            g.fds[fd] = nil
            fclose(f)
    return 0

func sys_sendfile(g, a):
    let out = g.fds[a[0]]
    let inp = g.fds[a[1]]
    if out == nil or inp == nil:
        return -EBADF
    let off = -1
    if a[2] != 0:
        let ob = rd(g, a[2], 8)
        if ob == nil:
            return -EFAULT
        off = u64(ob, 0)
    let data = do_read(g, inp, a[3], off)
    if type(data) == "int":
        return data
    let r = do_write(g, out, data)
    if r < 0:
        return r
    if a[2] != 0:
        let nb = []
        for i in range(8):
            nb.append(0)
        put64(nb, 0, off + r)
        wr(g, a[2], sslcore.concat([nb]))
    elif inp.kind == "file":
        inp.pos += r
    return r

func sys_copy_file_range(g, a):
    let inp = g.fds[a[0]]
    let out = g.fds[a[2]]
    if inp == nil or out == nil:
        return -EBADF
    let data = do_read(g, inp, a[4], -1)
    if type(data) == "int":
        return data
    if inp.kind == "file":
        inp.pos += len(data)
    return do_write(g, out, data)

func sys_noop_ok(g, a):
    return 0

# ---- readiness: poll, select, epoll, eventfd ----
const POLLIN = 1
const POLLOUT = 4
const POLLERR = 8
const POLLHUP = 16

let waiters = []     # [thread, check function, deadline (0 = none), result on timeout]

# block the calling thread until check() gives a result (not nil), or the timeout; timeout_ms < 0: for ever, 0: do not wait
func block(check, timeout_ms, tres):
    let r = check()
    if r != nil:
        return r
    if timeout_ms == 0:
        return tres
    waiters.append([cur_tid, check, 0 if timeout_ms < 0 else psys.ms() + timeout_ms, tres])
    return nil

func recheck():
    if len(waiters) == 0:
        return nil
    let now = psys.ms()
    let keep = []
    let list = waiters
    waiters = []
    for w in list:
        if tmap[w[0]] == nil:
            continue
        let r = w[1]()
        if r == nil and w[2] != 0 and now >= w[2]:
            r = w[3]
        if r != nil:
            lx.reply(w[0], r)
        else:
            keep.append(w)
    for w in waiters:
        keep.append(w)
    waiters = keep

func waiter_deadline():
    let best = 0
    for w in waiters:
        if w[2] != 0:
            let d = imax(1, w[2] - psys.ms())
            if best == 0 or d < best:
                best = d
    return best

# which of POLLIN / POLLOUT / POLLHUP / POLLERR a descriptor has now
func fd_ready(f):
    let k = f.kind
    if k == "file" or k == "null" or k == "zero" or k == "random" or k == "dir" or k == "mem":
        return POLLIN | POLLOUT
    if k == "console":
        return POLLOUT
    if k == "stdin":
        return POLLIN
    if k == "pipe":
        let p = f.pipe
        if f.end == "r":
            let r = 0
            if p.size > 0:
                r = POLLIN
            if p.writers == 0:
                r = r | POLLHUP | POLLIN
            return r
        return POLLERR if p.readers == 0 else POLLOUT
    if k == "eventfd":
        return (POLLIN if f.count > 0 else 0) | POLLOUT
    if k == "epoll":
        return POLLIN if len(epoll_ready(f, 1)) > 0 else 0
    if k == "sock":
        return POLLIN | POLLOUT
    return POLLIN | POLLOUT

func sys_poll_core(g, fds_addr, nfds, timeout_ms):
    if nfds > 4096:
        return -EINVAL
    func check():
        let raw = rd(g, fds_addr, nfds * 8)
        if raw == nil:
            return -EFAULT
        let count = 0
        let out = []
        for i in range(nfds):
            let fd = u32(raw, i * 8)
            if fd >= 2147483648:
                fd -= 4294967296
            let ev = u16(raw, i * 8 + 4)
            let rev = 0
            if fd >= 0:
                let f = g.fds[fd]
                if f == nil:
                    rev = 32          # POLLNVAL
                else:
                    rev = fd_ready(f) & (ev | POLLERR | POLLHUP)
            if rev != 0:
                count += 1
            put16(raw, i * 8 + 6, rev)
        if count == 0:
            return nil
        wr(g, fds_addr, raw)
        return count
    return block(check, timeout_ms, 0)

func sys_poll(g, a):
    let t = a[2]
    if t >= 2147483648:
        t -= 4294967296
    if t < 0 and a[2] != 0:
        t = -1
    return sys_poll_core(g, a[0], a[1], t)

func ts_ms(g, addr):
    if addr == 0:
        return -1
    let ts = rd(g, addr, 16)
    if ts == nil:
        return nil
    return u64(ts, 0) * 1000 + (u64(ts, 8) + 999999) // 1000000

func sys_ppoll(g, a):
    let t = ts_ms(g, a[2])
    if t == nil:
        return -EFAULT
    return sys_poll_core(g, a[0], a[1], t)

func fdset_get(raw, i):
    return (raw[i // 8] >> (i % 8)) & 1

func sys_select_core(g, nfds, rp, wp, ep, timeout_ms):
    let nbytes = (nfds + 7) // 8
    func check():
        let rr = rd(g, rp, nbytes) if rp != 0 else nil
        let wrr = rd(g, wp, nbytes) if wp != 0 else nil
        let outr = []
        let outw = []
        for i in range(nbytes):
            outr.append(0)
            outw.append(0)
        let count = 0
        for fd in range(nfds):
            let f = g.fds[fd]
            if rr != nil and fdset_get(rr, fd) == 1:
                if f == nil:
                    return -EBADF
                if (fd_ready(f) & (POLLIN | POLLHUP)) != 0:
                    outr[fd // 8] = outr[fd // 8] | (1 << (fd % 8))
                    count += 1
            if wrr != nil and fdset_get(wrr, fd) == 1:
                if f == nil:
                    return -EBADF
                if (fd_ready(f) & POLLOUT) != 0:
                    outw[fd // 8] = outw[fd // 8] | (1 << (fd % 8))
                    count += 1
        if count == 0:
            return nil
        if rp != 0:
            wr(g, rp, sslcore.concat([outr]))
        if wp != 0:
            wr(g, wp, sslcore.concat([outw]))
        if ep != 0:
            wr(g, ep, sslcore.concat([zeros(nbytes)]))
        return count
    return block(check, timeout_ms, 0)

func zeros(n):
    let z = []
    for i in range(n):
        z.append(0)
    return z

func sys_select(g, a):
    let t = -1
    if a[4] != 0:
        let tv = rd(g, a[4], 16)
        if tv == nil:
            return -EFAULT
        t = u64(tv, 0) * 1000 + u64(tv, 8) // 1000
    let r = sys_select_core(g, a[0], a[1], a[2], a[3], t)
    if r == 0 and a[1] != 0:
        wr(g, a[1], sslcore.concat([zeros((a[0] + 7) // 8)]))
    return r

func sys_pselect6(g, a):
    let t = ts_ms(g, a[4])
    if t == nil:
        return -EFAULT
    let r = sys_select_core(g, a[0], a[1], a[2], a[3], t)
    if r == 0 and a[1] != 0:
        wr(g, a[1], sslcore.concat([zeros((a[0] + 7) // 8)]))
    return r

# epoll: a set of watched descriptors; level triggered
func sys_epoll_create(g, a):
    return g.alloc_fd({kind: "epoll", watches: {}})

func sys_epoll_ctl(g, a):
    let ep = g.fds[a[0]]
    if ep == nil or ep.kind != "epoll":
        return -EBADF
    let f = g.fds[a[2]]
    if f == nil:
        return -EBADF
    if a[1] == 2:
        ep.watches[a[2]] = nil
        return 0
    let ev = rd(g, a[3], 12)
    if ev == nil:
        return -EFAULT
    if a[1] == 1 and ep.watches[a[2]] != nil:
        return -EEXIST
    if a[1] == 3 and ep.watches[a[2]] == nil:
        return -ENOENT
    ep.watches[a[2]] = [u32(ev, 0), u64(ev, 4), f]
    return 0

func epoll_ready(ep, maxn):
    let out = []
    for fd in ep.watches:
        let w = ep.watches[fd]
        if w == nil:
            continue
        let r = fd_ready(w[2]) & (w[0] | POLLERR | POLLHUP)
        if (w[0] & 0x2000) != 0 and (fd_ready(w[2]) & POLLHUP) != 0:
            r = r | 0x2000
        if r != 0:
            out.append([r, w[1], fd])
            if len(out) >= maxn:
                break
    return out

func sys_epoll_wait(g, a):
    let ep = g.fds[a[0]]
    if ep == nil or ep.kind != "epoll":
        return -EBADF
    if a[2] <= 0:
        return -EINVAL
    let t = a[3]
    if t >= 2147483648:
        t -= 4294967296
    func check():
        let ready = epoll_ready(ep, a[2])
        if len(ready) == 0:
            return nil
        let b = []
        for i in range(12 * len(ready)):
            b.append(0)
        for i in range(len(ready)):
            put32(b, i * 12, ready[i][0])
            put64(b, i * 12 + 4, ready[i][1])
            let w = ep.watches[ready[i][2]]
            if (w[0] & (1 << 30)) != 0:        # EPOLLONESHOT
                ep.watches[ready[i][2]] = nil
        wr(g, a[1], sslcore.concat([b]))
        return len(ready)
    return block(check, t, 0)

func sys_eventfd(g, a):
    return g.alloc_fd({kind: "eventfd", count: a[0], sem: (a[1] & 1) != 0})

func eventfd_read(g, f, buf):
    func check():
        if f.count == 0:
            return nil
        let v = 1 if f.sem else f.count
        f.count -= v
        let b = []
        for i in range(8):
            b.append(0)
        put64(b, 0, v)
        wr(g, buf, sslcore.concat([b]))
        return 8
    return block(check, -1, 0)

func eventfd_write(g, f, b):
    if len(b) < 8:
        return -EINVAL
    f.count += u64(b, 0)
    return 8


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
    table[13] = sys_sigaction
    table[24] = sys_zero
    table[56] = sys_clone
    table[200] = sys_tkill
    table[204] = sys_sched_getaffinity
    table[234] = sys_tgkill
    table[273] = sys_zero
    table[14] = sys_zero
    table[16] = sys_ioctl
    table[17] = sys_pread
    table[18] = sys_pwrite
    table[20] = sys_writev
    table[21] = sys_access
    table[25] = sys_mremap
    table[28] = sys_zero
    table[22] = sys_pipe
    table[293] = sys_pipe
    table[32] = sys_dup
    table[57] = sys_fork
    table[58] = sys_fork
    table[59] = sys_execve
    table[61] = sys_wait4
    table[62] = sys_kill
    table[110] = sys_getppid
    table[33] = sys_dup2
    table[35] = sys_nanosleep
    table[39] = sys_getpid
    table[60] = sys_exit_thread
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
    table[111] = sys_getpid
    table[131] = sys_zero
    table[158] = sys_arch_prctl
    table[186] = sys_gettid
    table[202] = sys_futex
    table[217] = sys_getdents64
    table[218] = sys_set_tid_address
    table[228] = sys_clock_gettime
    table[230] = sys_clock_nanosleep
    table[231] = sys_exit
    table[257] = sys_openat
    table[262] = sys_newfstatat
    table[269] = sys_faccessat
    table[273] = sys_zero
    table[302] = sys_prlimit64
    table[318] = sys_getrandom
    table[7] = sys_poll
    table[19] = sys_readv
    table[23] = sys_select
    table[26] = sys_noop_ok
    table[27] = sys_noop_ok
    table[40] = sys_sendfile
    table[73] = sys_noop_ok
    table[74] = sys_noop_ok
    table[75] = sys_noop_ok
    table[76] = sys_truncate
    table[81] = sys_fchdir
    table[85] = sys_creat
    table[90] = sys_noop_ok
    table[91] = sys_noop_ok
    table[92] = sys_noop_ok
    table[93] = sys_noop_ok
    table[95] = sys_umask
    table[97] = sys_getrlimit
    table[98] = sys_getrusage
    table[100] = sys_times
    table[105] = sys_noop_ok
    table[106] = sys_noop_ok
    table[109] = sys_noop_ok
    table[112] = sys_getpid
    table[113] = sys_noop_ok
    table[115] = sys_getgroups
    table[118] = sys_getresuid
    table[121] = sys_getpid
    table[124] = sys_getpid
    table[137] = sys_statfs
    table[138] = sys_statfs
    table[157] = sys_prctl
    table[160] = sys_noop_ok
    table[162] = sys_noop_ok
    table[201] = sys_time
    table[203] = sys_noop_ok
    table[213] = sys_epoll_create
    table[221] = sys_noop_ok
    table[229] = sys_clock_getres
    table[232] = sys_epoll_wait
    table[233] = sys_epoll_ctl
    table[235] = sys_noop_ok
    table[258] = sys_mkdirat
    table[260] = sys_noop_ok
    table[263] = sys_unlinkat
    table[264] = sys_renameat
    table[267] = sys_readlinkat
    table[268] = sys_noop_ok
    table[270] = sys_pselect6
    table[271] = sys_ppoll
    table[277] = sys_noop_ok
    table[280] = sys_noop_ok
    table[281] = sys_epoll_wait
    table[284] = sys_eventfd
    table[285] = sys_noop_ok
    table[290] = sys_eventfd
    table[291] = sys_epoll_create
    table[292] = sys_dup3
    table[295] = sys_preadv
    table[296] = sys_pwritev
    table[309] = sys_getcpu
    table[316] = sys_renameat
    table[326] = sys_copy_file_range
    table[327] = sys_preadv
    table[328] = sys_pwritev
    table[332] = sys_statx
    table[436] = sys_close_range
    table[439] = sys_faccessat2
    table[452] = sys_noop_ok

# one forwarded system call of guest `g`
func serve_call(g, q):
    let nr = to_int(q[0])
    let a = []
    for i in range(1, 7):
        a.append(to_int(q[i]))
    g.calls += 1
    let f = table[nr]
    let t_start = psys.ms()
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
    if verbose and psys.ms() - t_start > 150:
        log("slow: tid " .. to_string(cur_tid) .. " syscall " .. to_string(nr) .. " (" .. to_string(a[0]) .. "," .. to_string(a[1]) .. "," .. to_string(a[2]) .. ") took " .. to_string(psys.ms() - t_start) .. " ms")
    if verbose == "trace" and cur_tid >= 8:
        log("tid " .. to_string(cur_tid) .. " syscall " .. to_string(nr) .. " (" .. to_string(a[0]) .. "," .. to_string(a[1]) .. "," .. to_string(a[2]) .. ") = " .. to_string(r))
    if r != nil:
        lx.reply(cur_tid, r)

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
        verbose = q[1] if len(q) > 1 else true
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
    let tmo = next_wake()
    let wd = waiter_deadline()
    if wd != 0 and (tmo == 0 or wd < tmo):
        tmo = wd
    let m = nil
    if fs != nil and len(fs.backlog) > 0:
        m = fs.backlog.remove_at(0)           # a message that came in while we waited for fsd
    else:
        m = ipc.recv_from(true, tmo)
    wake_sleepers()
    if m == nil:
        recheck()
        continue
    let src = m[0]
    let text = m[1]
    if verbose == "trace" and src >= 8:
        log("recv from " .. to_string(src) .. ": " .. text.slice(0, 30))
    let g = tmap[src]
    if g != nil:
        if text.starts_with("X\t"):
            # the kernel ended it (a fault): the whole process goes
            let code = to_int(text.slice(2))
            ended(g, 11 if code == 139 else code)
        else:
            cur_tid = src
            serve_call(g, text.split("\t"))
    elif text.starts_with("X\t"):
        pass          # a program we already finished
    else:
        running = serve_request(src, text)
    recheck()
log("bye")
