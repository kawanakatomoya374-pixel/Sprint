# linuxd: the Linux personality server. It runs x86-64 Linux programs (static-pie, or dynamic with their interpreter) as ordinary SprintOS processes whose
# system calls the kernel forwards to this process as messages. The kernel only has a handful of mechanisms for it (lx module: create a process, map /
# unmap / protect memory in it, copy bytes in and out, start it, answer a system call, kill it); everything Linux - the file descriptors, paths, the
# system call table, the ELF loader, the initial stack - is here, in Sprint, on top of the file system server.
#
# A client starts a program with the message  "run<TAB>path<TAB>arg0<US>arg1...<TAB>env0<US>env1..."  (US = byte 0x1f) and receives "ok<TAB>pid" or
# "err<TAB>why", and later "exit<TAB>pid<TAB>status" when the program ended. The server registers as "linux".
import io
import ipc
import uio
import lx
import psys
import fsclient
import sslcore
import netstack
import typed

const USER_BASE = 0x8000000000
const STACK_TOP = USER_BASE + 0x7000000000     # far above the mmap area (the JVM reserves gigabytes)
const STACK_SIZE = 8 << 20
const PIE_BASE = USER_BASE + 0x400000
const INTERP_BASE = USER_BASE + 0x8000000       # (below the mmap area: a program that reserves 128 GB must not run over the dynamic loader)
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
const AF_UNIX = 1
const AF_INET = 2
const AF_INET6 = 10
const ECONNREFUSED = 111
const EADDRINUSE = 98
const EISCONN = 106
const ENOTCONN = 107
const EAFNOSUPPORT = 97
const EPIPE = 32
const ENETUNREACH = 101

let fs = nil
let guests = {}           # pid of the first thread -> Guest (a process)
let tmap = {}             # thread id -> the Guest it belongs to
let clear_tids = {}       # thread id -> address to clear (and wake) when the thread ends
let cur_tid = 0           # the thread whose system call is being served
let futex_q = {}          # "pid:address" -> [[tid, bitset], ...]
let table = {}            # system call number -> function(g, a)
let verbose = false
let prof = {}             # system call number -> [calls, ms] (verbose "prof")
let prof_busy = 0
let next_beat = 0
let prof_wr = 0
let prof_wrn = 0
let prof_rd = 0
let shm_segs = {}         # System V segments, see sys_shmget
let shm_next = 1
let shm_attached = {}     # pid -> {address -> [shmid, pages]}
let waiters = []     # [thread, check function, deadline (0 = none), result on timeout]
let tmask = {}          # tid -> blocked signals (bit sig-1)
let tpend = {}          # tid -> signals sent to that thread
let altstk = {}         # tid -> [sp, size]
let savedmask = {}      # tid -> the mask to restore when a sigsuspend handler returns
let blocked = {}        # tid -> function that takes the thread out of the wait it is in (so a signal can interrupt it)
let last_nr = {}        # tid -> the system call being served (to restart it)
let alarms = {}         # pid -> [deadline ms, interval ms]

func log(s):
    print("[linuxd] " .. s)
    io.flush()

# a C int argument arrives zero-extended in its 64-bit register: make it signed again
func i32(v):
    return v - 4294967296 if v >= 2147483648 and v < 4294967296 else v

# the keys of a table as an array (so the table may be changed while they are walked)
func keys(t):
    let out = []
    for k in t:
        out.append(k)
    return out

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
    let sigs = nil            # signal -> [handler, flags, restorer, mask]
    let pend = 0              # signals sent to the process (bit sig-1)
    let vm = nil              # memory map for /proc/self/maps: [start, end, prot (4 r, 2 w, 1 x), name]
    let argv = nil
    let envp = nil
    let heap_start = 0
    let lazy = nil            # file mappings filled on first touch: [start, end, path, file offset, {page -> true}]
    func init(self, pid, client):
        self.pid = pid
        self.client = client
        self.children = {}
        self.zombies = {}
        self.tids = {}
        self.tids[pid] = true
        self.vm = []
        self.lazy = []
        self.argv = []
        self.envp = []
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
    if f.kind == "sock":
        sock_close(f)
        return nil
    if f.kind == "pipe":
        let p = f.pipe
        if f.end == "r":
            p.readers -= 1
        else:
            p.writers -= 1
            pipe_wake(p)

func release_fds(g):
    for fd in keys(g.fds):
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
    let t0 = psys.ms()
    let r = lx.write(g.pid, addr, b)
    prof_wr += psys.ms() - t0
    prof_wrn += len(b)
    return 0 if r == 0 else -EFAULT

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

# symbolic links: target of the link at `path`, or nil when it is not one (cached; any change of the name space clears the cache)
let linkcache = {}
func link_target(path):
    let c = linkcache[path]
    if c != nil:
        return c if c != false else nil
    let t = nil
    try:
        let st = fs.lstat(path)
        if st.kind == "symlink":
            t = fs.readlink(path)
    catch e:
        t = nil
    if len(linkcache) > 20000:
        linkcache = {}
    linkcache[path] = t if t != nil else false
    return t

func links_changed():
    linkcache = {}

# the path with every symbolic link in it replaced by what it points to (the last component too when follow_last)
func resolve(p, follow_last):
    if p.starts_with("/proc") or p.starts_with("/dev") or fs == nil:
        return p
    let parts = p.split("/").filter(x => x != "")
    let cur = ""
    let i = 0
    let depth = 0
    while i < len(parts):
        let comp = parts[i]
        let cand = cur .. "/" .. comp
        if comp == "." or comp == "":
            i += 1
            continue
        if comp == "..":
            let k = last_slash(cur)
            cur = cur.slice(0, k) if k > 0 else ""
            i += 1
            continue
        if i < len(parts) - 1 or follow_last:
            let t = link_target(cand)
            if t != nil:
                depth += 1
                if depth > 40:
                    return cand
                let rest = parts.slice(i + 1)
                let np = t.split("/").filter(x => x != "")
                parts = join_arrays(np, rest)
                if t.starts_with("/"):
                    cur = ""
                i = 0
                continue
        cur = cand
        i += 1
    return cur if cur != "" else "/"

func join_arrays(a, b):
    let out = []
    for x in a:
        out.append(x)
    for x in b:
        out.append(x)
    return out

func abspath(g, p):
    if p.starts_with("/"):
        return resolve(norm(p), true)
    return resolve(norm(g.cwd .. "/" .. p), true)

# the same but a link in the last place stays what it is (lstat, readlink, unlink, rename, symlink)
func abspath_nf(g, p):
    if p.starts_with("/"):
        return resolve(norm(p), false)
    return resolve(norm(g.cwd .. "/" .. p), false)

# ---- the memory map of a program (for /proc/self/maps) ----
func vm_remove(g, a, b):
    let out = []
    for r in g.vm:
        if r[1] <= a or r[0] >= b:
            out.append(r)
            continue
        if r[0] < a:
            out.append([r[0], a, r[2], r[3]])
        if r[1] > b:
            out.append([b, r[1], r[2], r[3]])
    g.vm = out

func vm_add(g, a, b, prot, name):
    vm_remove(g, a, b)
    g.vm.append([a, b, prot, name])

func vm_protect(g, a, b, prot):
    let out = []
    for r in g.vm:
        if r[1] <= a or r[0] >= b:
            out.append(r)
            continue
        if r[0] < a:
            out.append([r[0], a, r[2], r[3]])
        out.append([imax(r[0], a), imin(r[1], b), prot, r[3]])
        if r[1] > b:
            out.append([b, r[1], r[2], r[3]])
    g.vm = out

func hexn(v):
    if v == 0:
        return "0"
    let d = "0123456789abcdef"
    let out = ""
    let x = v
    while x > 0:
        out = d.slice(x & 15, (x & 15) + 1) .. out
        x = x >> 4
    return out

func padn(s, n):
    let o = s
    while len(o) < n:
        o = "0" .. o
    return o

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
            segs.append([va, off, filesz, memsz, u32(img, ph + 4)])
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
    return {entry: u64(img, 24) + b, phdr: phdr + b, phent: phent, phnum: phnum, base: b, top: align_up(top + b), interp: interp, segs: segs}

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
    g.heap_start = g.brk
    g.mmap_next = MMAP_BASE
    g.vm = []
    g.lazy = []
    g.argv = argv
    g.envp = envp
    for sg in info.segs:
        vm_add(g, (sg[0] + info.base) & ~4095, align_up(sg[0] + info.base + sg[3]), sg[4] & 7, path)
    if info.interp != nil:
        vm_add(g, INTERP_BASE, INTERP_BASE + 0x40000, 5, info.interp)
    vm_add(g, STACK_TOP - STACK_SIZE, STACK_TOP, 6, "[stack]")
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
    if f.kind == "null":
        return n                      # nothing to copy
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
    if f.kind == "sock":
        return sock_send(g, f, b, 0, nil)
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
    if f.kind == "mem":
        let at = f.pos if off < 0 else off
        let want = imin(n, len(f.data) - at)
        if want <= 0:
            return sslcore.concat([[]])
        return f.data.slice(at, at + want)
    if f.kind != "file":
        return -EBADF
    if not f.readable:
        return -EBADF
    try:
        # the size and the cached whole file are looked up once and stay good until something on the volume changes
        if f.cgen != fs.gen or f.csize == nil:
            let st = fs.stat(f.path)
            f.csize = st.size
            f.cwhole = cached_file(f.path)
            f.cgen = fs.gen
        let size = f.csize
        let at = f.pos if off < 0 else off
        let want = imin(n, size - at)
        if want <= 0:
            return sslcore.concat([[]])
        let whole = f.cwhole
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
    if f.kind == "sock":
        return sys_recvfrom(g, [a[0], a[1], a[2], 0, 0, 0])
    if f.kind == "eventfd":
        return eventfd_read(g, f, a[1])
    if f.kind == "timerfd":
        return timerfd_read(g, f, a[1])
    if f.kind == "pipe":
        if f.end != "r":
            return -EBADF
        let p = f.pipe
        if p.size == 0:
            if p.writers == 0:
                return 0
            if f.nonblock:
                return -11
            p.rwait.append([g, a[1], a[2], cur_tid])
            let tid = cur_tid
            blocked[tid] = () => cancel_pipe_wait(p, tid)
            return nil
        let chunk = pipe_take(p, imin(a[2], p.size))
        let e0 = wr(g, a[1], chunk)
        return e0 if e0 < 0 else len(chunk)
    let t0 = psys.ms()
    let r = do_read(g, f, a[2], -1)
    prof_rd += psys.ms() - t0
    if type(r) == "int":
        return r
    if f.kind == "file" or f.kind == "mem":
        f.pos += len(r)
    let e = wr(g, a[1], r)
    return e if e < 0 else len(r)

func sys_pread(g, a):
    let f = g.fds[a[0]]
    if f == nil or (f.kind != "file" and f.kind != "mem"):
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
    if f.kind != "file" and f.kind != "dir" and f.kind != "mem":
        return -ESPIPE
    let base = 0
    if a[2] == 1:
        base = f.pos
    elif a[2] == 2:
        if f.kind == "mem":
            base = len(f.data)
        else:
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
    if verbose == "paths" or verbose == "trace":
        log("open " .. p .. " by " .. to_string(g.pid))
    if p == "/dev/null":
        return g.alloc_fd({kind: "null"})
    if p == "/dev/zero":
        return g.alloc_fd({kind: "zero"})
    if p == "/dev/urandom" or p == "/dev/random":
        return g.alloc_fd({kind: "random"})
    if p == "/dev/tty" or p == "/dev/console":
        return g.alloc_fd({kind: "console", fd: 1})
    if p.starts_with("/proc") or p == "/dev" or p.starts_with("/dev/fd") or p == "/dev/stdin" or p == "/dev/stdout" or p == "/dev/stderr":
        let vfd = open_virtual(g, p)
        if vfd != nil:
            return vfd
        if p.starts_with("/dev/std") or p.starts_with("/dev/fd/"):
            let n = 0 if p == "/dev/stdin" else (1 if p == "/dev/stdout" else (2 if p == "/dev/stderr" else to_int(p.slice(8))))
            let src = g.fds[n]
            if src == nil:
                return -ENOENT
            return g.alloc_fd(src)
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
            links_changed()
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

func stat_path(g, p, buf, follow = true):
    let ap = abspath(g, p) if follow else abspath_nf(g, p)
    if ap == "/dev/null" or ap == "/dev/zero" or ap == "/dev/urandom" or ap == "/dev/tty":
        let b = fill_stat("file", 0, 0, 3)
        b[24] = 0o20666 & 255
        b[25] = (0o20666 >> 8) & 255
        return wr(g, buf, b)
    if ap.starts_with("/proc") or ap == "/dev" or ap.starts_with("/dev/fd") or ap == "/dev/stdin" or ap == "/dev/stdout" or ap == "/dev/stderr":
        let vk = virtual_stat_kind(g, ap)
        if vk != nil:
            let sz = 0
            if vk == "file":
                sz = 0
            return wr(g, buf, fill_stat(vk, sz, 0, path_ino(ap)))
    try:
        let st = fs.stat(ap) if follow else fs.lstat(ap)
        return wr(g, buf, fill_stat(st.kind, st.size, st.mtime, path_ino(ap)))
    catch e:
        return -errno_of(e.kind)

func sys_stat(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    return stat_path(g, path, a[1])

func sys_lstat(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    return stat_path(g, path, a[1], false)

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
    if f.kind == "mem":
        return wr(g, a[1], fill_stat("file", len(f.data), 0, path_ino(f.path)))
    if f.kind == "dir" and f.virtual == true:
        return wr(g, a[1], fill_stat("dir", 0, 0, path_ino(f.path)))
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
    return stat_path(g, path, a[2], (a[3] & 0x100) == 0)

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
        links_changed()
        fs.unlink(abspath_nf(g, path))
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_rmdir(g, a):
    let path = cstr(g, a[0])
    if path == nil:
        return -EFAULT
    try:
        links_changed()
        fs.rmdir(abspath_nf(g, path))
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_rename(g, a):
    let p1 = cstr(g, a[0])
    let p2 = cstr(g, a[1])
    if p1 == nil or p2 == nil:
        return -EFAULT
    try:
        links_changed()
        fs.rename(abspath_nf(g, p1), abspath_nf(g, p2))
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
    let f = g.fds[a[0]]
    if a[1] == 0 or a[1] == 1030:       # F_DUPFD, F_DUPFD_CLOEXEC
        return g.alloc_fd(f, a[2])
    if a[1] == 3:                       # F_GETFL: the access mode and O_NONBLOCK
        let acc = 0
        if f.kind == "file":
            acc = 2 if (f.readable and f.writable) else (1 if f.writable else 0)
        elif f.kind == "pipe":
            acc = 1 if f.end == "w" else 0
        elif f.kind == "sock" or f.kind == "console":
            acc = 2
        return acc | (0o4000 if f.nonblock else 0) | (0o2000 if f.append else 0)
    if a[1] == 4:                       # F_SETFL
        f.nonblock = (a[2] & 0o4000) != 0
        return 0
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
        vm_remove(g, g.heap_start & ~4095, g.brk_end)
        vm_add(g, g.heap_start & ~4095, g.brk_end, 6, "[heap]")
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
        if not vm_free(g, addr, addr + n):         # something is already there (the loader, an earlier fixed mapping): go above everything
            let top = addr
            for r in g.vm:
                if r[1] > top and r[0] < STACK_TOP - STACK_SIZE:
                    top = r[1]
            addr = align_up(top) + 4096
        g.mmap_next = addr + n + 4096
    let f = nil
    if (flags & 0x20) == 0:
        f = g.fds[i32(fd)]
        if f == nil or f.kind != "file":
            return -EBADF
    if f != nil and f.kind == "file" and (flags & 0x03) == 1 and (prot & 2) != 0 and (off & 4095) == 0:
        # writable and shared: the pages are the file's segment, not a private copy
        let size = 0
        try:
            size = fs.stat(f.path).size
        catch err:
            size = 0
        let e = shared_file(f.path, align_up(imax(size, off + length)))
        lx.unmap(g.pid, addr, n)
        let r = lx.shm_attach(g.pid, addr, e[0], off // 4096, n // 4096)
        if r < 0:
            return -ENOMEM
        lazy_remove(g, addr, addr + n)
        vm_remove(g, addr, addr + n)
        vm_add(g, addr, addr + n, prot & 7, f.path)
        return addr
    if f != nil and f.kind == "file" and n >= (1 << 20) and (flags & 0x03) != 0:
        # a big file (the JVM's 130 MB class library): pages are read when the program touches them
        if lx.map(g.pid, addr, n, (3 if (prot & 2) != 0 else 1) | 4) != 0:
            return -ENOMEM
        lazy_remove(g, addr, addr + n)          # (what this mapping replaces is no longer filled from an older one)
        vm_add(g, addr, addr + n, prot & 7, f.path)
        g.lazy.append([addr, addr + n, f.path, off, {}, {kind: "file", path: f.path, readable: true, pos: 0}])
        return addr
    if lx.map(g.pid, addr, n, 3 if f != nil else (3 if (prot & 2) != 0 else 1)) != 0:
        return -ENOMEM
    lazy_remove(g, addr, addr + n)              # a MAP_FIXED over part of a lazy file mapping (a library's data segment): those pages are not lazy any more
    vm_add(g, addr, addr + n, prot & 7, f.path if f != nil and f.kind == "file" else "")
    if f != nil:
        let data = do_read(g, f, length, off)
        if type(data) == "int":
            return data
        if len(data) > 0 and lx.write(g.pid, addr, data) != 0:
            return -EFAULT
        if (prot & 2) == 0:
            lx.protect(g.pid, addr, n, 1)
    return addr

func lazy_remove(g, a, b):
    if len(g.lazy) == 0:
        return 0
    let out = []
    for e in g.lazy:
        if e[1] <= a or e[0] >= b:
            out.append(e)
        elif e[0] >= a and e[1] <= b:
            pass
        elif e[0] >= a:
            e[3] += b - e[0]
            e[0] = b
            out.append(e)
        elif e[1] <= b:
            e[1] = a
            out.append(e)
        else:                                       # a hole in the middle: two pieces of the same mapping
            out.append([e[0], a, e[2], e[3], e[4], e[5]])
            out.append([b, e[1], e[2], e[3] + (b - e[0]), e[4], e[5]])
    g.lazy = out
    return 0

# ---- MAP_SHARED, writable file mappings (the X server's screen in /dev/shm, MIT-SHM images): one kernel segment per file, so every program that maps the file sees the same memory ----
let sharedfiles = {}      # path -> [kernel segment id, linuxd's own address of it, bytes]

func shared_file(path, bytes):
    let e = sharedfiles[path]
    if e != nil and e[2] >= bytes:
        return e
    let seg = ipc.shm_create(bytes)
    try:
        let st = fs.stat(path)
        if st.size > 0:
            ipc.shm_put(seg[1], 0, fs.read_bytes(path, 0, imin(st.size, seg[2])))
    catch err:
        pass
    e = [seg[0], seg[1], seg[2]]
    sharedfiles[path] = e
    return e

# the memory of a shared file mapping back into the file
func shared_writeback(path):
    let e = sharedfiles[path]
    if e == nil:
        return -ENOENT
    try:
        let size = fs.stat(path).size
        fs.write_bytes(path, ipc.shm_bytes(e[1], 0, imin(size, e[2])), 0, false)
        return 0
    catch err:
        return -errno_of(err.kind)

func sys_msync(g, a):
    let r = vm_find(g, a[0])
    if r != nil and sharedfiles[r[3]] != nil:
        return shared_writeback(r[3])
    return 0

# a first touch of a page of a big file mapping: read the next 64 KB window (pages not filled before) from the file, then let the instruction run again
func serve_lazy(g, tid, q):
    let addr = to_int(q[1])
    let pg = addr & ~4095
    for e in g.lazy:
        if pg >= e[0] and pg < e[1]:
            let hi = imin(e[1], (pg & ~65535) + 65536)
            let lo = imax(pg & ~65535, e[0])
            while lo < hi and e[4][lo >> 12] != nil and lo != pg:
                lo += 4096
            let data = do_read(g, e[5], hi - lo, e[3] + (lo - e[0]))
            if type(data) == "int":
                data = sslcore.concat([[]])
            let b = data
            if len(b) < hi - lo:
                let z = []
                for i in range(hi - lo - len(b)):
                    z.append(0)
                b = sslcore.concat([data, sslcore.concat([z])])
            let a2 = lo
            while a2 < hi:
                if e[4][a2 >> 12] == nil:
                    lx.write(g.pid, a2, b.slice(a2 - lo, a2 - lo + 4096))
                    e[4][a2 >> 12] = true
                a2 += 4096
            lx.resume(tid)
            return nil
    serve_fault(g, tid, ["F", "14", to_string(addr), "4"])

func sys_munmap(g, a):
    if (a[0] & 4095) != 0:
        return -EINVAL
    lx.unmap(g.pid, a[0], a[1])
    vm_remove(g, a[0], a[0] + align_up(a[1]))
    lazy_remove(g, a[0], a[0] + align_up(a[1]))
    return 0

func sys_mprotect(g, a):
    lx.protect(g.pid, a[0] & ~4095, a[1], a[2])
    vm_protect(g, a[0] & ~4095, (a[0] & ~4095) + align_up(a[1]), a[2] & 7)
    return 0

# is [a, b) free of mappings?
func vm_free(g, a, b):
    for r in g.vm:
        if r[0] < b and r[1] > a:
            return false
    return true

func vm_find(g, addr):
    for r in g.vm:
        if addr >= r[0] and addr < r[1]:
            return r
    return nil

func sys_mremap(g, a):
    let old = a[0]
    let oldlen = align_up(a[1])
    let newlen = align_up(a[2])
    let r = vm_find(g, old)
    if r == nil or (old & 4095) != 0:
        return -EFAULT                   # (musl's pthread_getattr_np probes the stack with this: unmapped must be EFAULT)
    if newlen == 0:
        return -EINVAL
    if newlen <= oldlen:
        if newlen < oldlen:
            lx.unmap(g.pid, old + newlen, oldlen - newlen)
            vm_remove(g, old + newlen, old + oldlen)
        return old
    # grow in place when the pages after it are free
    if vm_free(g, old + oldlen, old + newlen):
        if lx.map(g.pid, old + oldlen, newlen - oldlen, 3) != 0:
            return -ENOMEM
        vm_add(g, old + oldlen, old + newlen, r[2], r[3])
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
    vm_remove(g, old, old + oldlen)
    vm_add(g, na, na + newlen, r[2], r[3])
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
    shm_exit(g.pid)
    for t in keys(g.tids):
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
    alarms[g.pid] = nil
    let par = guests[g.parent] if g.parent != 0 else nil
    if par != nil:
        if par.waiting != nil and (par.waiting[0] == -1 or par.waiting[0] == g.pid):
            # (a parent blocked in wait4 gets the child, and a SIGCHLD handler runs when that call returns)
            let h17 = par.sigs[17]
            if h17 != nil and h17[0] > 1:
                par.pend = par.pend | sigbit(17)
        else:
            post_signal(par, 0, 17, nil)
        if par.waiting != nil and (par.waiting[0] == -1 or par.waiting[0] == g.pid):
            let w = par.waiting
            par.waiting = nil
            par.children[g.pid] = nil
            if w[1] != 0:
                let sb = []
                for i in range(4):
                    sb.append((status >> (8 * i)) & 255)
                wr(par, w[1], sslcore.concat([sb]))
            reply(w[3], g.pid)
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
        reply(w[3], r if r < 0 else n)

func cancel_pipe_wait(p, tid):
    let keep = []
    for w in p.rwait:
        if w[3] != tid:
            keep.append(w)
    p.rwait = keep

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
    let nb = (a[1] & 0o4000) != 0           # pipe2 flags
    let r = g.alloc_fd({kind: "pipe", pipe: p, end: "r", nonblock: nb})
    let w = g.alloc_fd({kind: "pipe", pipe: p, end: "w", nonblock: nb})
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
    c.heap_start = g.heap_start
    c.argv = g.argv
    c.envp = g.envp
    for r in g.vm:
        c.vm.append(r)
    for e in g.lazy:
        let d = {}
        for kx in keys(e[4]):
            d[kx] = true
        c.lazy.append([e[0], e[1], e[2], e[3], d, e[5]])
    shm_fork(g.pid, pid)
    for fd in g.fds:
        let f = g.fds[fd]
        if f != nil:
            c.fds[fd] = f
            f.refs += 1
    guests[pid] = c
    tmap[pid] = c
    g.children[pid] = true
    for sg in g.sigs:
        c.sigs[sg] = g.sigs[sg]
    tmask[pid] = tmask[cur_tid] ?? 0
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
    tmask[tid] = tmask[cur_tid] ?? 0
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

func sys_symlink(g, a):
    let target = cstr(g, a[0])
    let path = cstr(g, a[1])
    if target == nil or path == nil:
        return -EFAULT
    try:
        links_changed()
        fs.symlink(target, abspath_nf(g, path))
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_symlinkat(g, a):
    let target = cstr(g, a[0])
    let path = cstr(g, a[2])
    if target == nil or path == nil:
        return -EFAULT
    let p = at_path(g, a[1], path, false)
    if p == nil:
        return -EBADF
    try:
        links_changed()
        fs.symlink(target, p)
    catch e:
        return -errno_of(e.kind)
    return 0

func sys_sched_getaffinity(g, a):
    wr(g, a[2], sslcore.concat([[1, 0, 0, 0, 0, 0, 0, 0]]))
    return 8

func cancel_wait4(g):
    g.waiting = nil

func sys_wait4(g, a):
    let want = i32(a[0])
    let sp = a[1]
    for z in keys(g.zombies):
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
    let tid = cur_tid
    blocked[tid] = () => cancel_wait4(g)
    return nil

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
    for sg in keys(g.sigs):
        if g.sigs[sg][0] > 1:
            g.sigs[sg] = nil                  # handlers do not survive execve (ignored signals stay ignored)
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
func sleep_for(g, ms, rem = 0):
    let until = psys.ms() + ms
    sleepers.append([until, cur_tid, 0, nil])
    let tid = cur_tid
    blocked[tid] = () => cancel_sleep_rem(g, tid, until, rem)
    return nil

# a sleep that a signal cut short: the time left goes to the program's rem pointer
func cancel_sleep_rem(g, tid, until, rem):
    cancel_sleeper(tid)
    if rem != 0:
        let left = imax(0, until - psys.ms())
        let b = []
        for i in range(16):
            b.append(0)
        put64(b, 0, left // 1000)
        put64(b, 8, (left % 1000) * 1000000)
        wr(g, rem, sslcore.concat([b]))

func cancel_sleeper(tid):
    let keep = []
    for s in sleepers:
        if s[1] != tid:
            keep.append(s)
    sleepers = keep

func wake_sleepers():
    let now = psys.ms()
    let keep = []
    for s in sleepers:
        if s[0] <= now:
            if tmap[s[1]] != nil:
                if s[3] != nil:
                    futex_drop(s[3], s[1])
                reply(s[1], s[2])
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
        reply(w[0], 0)
        woken += 1
        # its timeout (if any) is cancelled
        let keep = []
        for s in sleepers:
            if not (s[1] == w[0] and s[3] != nil):
                keep.append(s)
        sleepers = keep
    return woken

func cancel_futex(key, tid):
    futex_drop(key, tid)
    cancel_sleeper(tid)

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
        let tid = cur_tid
        blocked[tid] = () => cancel_futex(key, tid)
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
    return sleep_for(g, u64(ts, 0) * 1000 + u64(ts, 8) // 1000000, a[1])

func sys_clock_nanosleep(g, a):
    let ts = rd(g, a[2], 16)
    if ts == nil:
        return -EFAULT
    let ms = u64(ts, 0) * 1000 + u64(ts, 8) // 1000000
    if (a[1] & 1) != 0:           # TIMER_ABSTIME
        ms = imax(0, ms - psys.ms())
    return sleep_for(g, ms, a[3] if (a[1] & 1) == 0 else 0)

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
    return readlink_path(g, abspath_nf(g, path), a[1], a[2])

func sys_sysinfo(g, a):
    let b = []
    for i in range(112):
        b.append(0)
    put64(b, 0, psys.ms() // 1000)
    put64(b, 32, 256 << 20)
    put64(b, 40, 128 << 20)
    put32(b, 104, 1)
    return wr(g, a[0], sslcore.concat([b]))


# ================= signals =================
const SA_ONSTACK = 0x08000000
const SA_RESTART = 0x10000000
const SA_NODEFER = 0x40000000
const SA_RESETHAND = 0x80000000
const SA_RESTORER = 0x04000000
const EINTR = 4

func sigbit(sig):
    return 1 << (sig - 1)

func sig_ignored_by_default(sig):
    return sig == 17 or sig == 18 or sig == 23 or sig == 28 or sig == 19 or sig == 20 or sig == 21 or sig == 22

func reply(tid, r):
    blocked[tid] = nil
    let g = tmap[tid]
    if g == nil:
        return nil
    let sig = next_deliverable(g, tid)
    if verbose == "trace":
        log("reply " .. to_string(tid) .. " " .. to_string(r) .. " sig " .. to_string(sig))
    if sig == nil:
        let rr = lx.reply(tid, r)
        if rr != 0:
            log("lx.reply to " .. to_string(tid) .. " failed: " .. to_string(rr))
        return nil
    deliver(g, tid, sig, r, r == -EINTR, nil)

func next_deliverable(g, tid):
    let avail = (tpend[tid] ?? 0) | g.pend
    if avail == 0:
        return nil
    let mask = (tmask[tid] ?? 0) & ~(sigbit(9) | sigbit(19))
    avail = avail & ~mask
    if avail == 0:
        return nil
    for sig in range(1, 65):
        if (avail & sigbit(sig)) != 0:
            return sig
    return nil

func kill_process(g, sig):
    lx.kill(g.pid, 128 + sig)
    ended(g, sig)

# ucontext / siginfo / FXSAVE frame on the program's stack, then run the handler; info = {code, addr, trapno, err}
func deliver(g, tid, sig, r, interrupted, info):
    if (tpend[tid] ?? 0) & sigbit(sig) != 0:
        tpend[tid] = tpend[tid] & ~sigbit(sig)
    else:
        g.pend = g.pend & ~sigbit(sig)
    let act = g.sigs[sig]
    let h = act[0] if act != nil else 0
    if h == 0 or h == 1:
        if h == 1 or sig_ignored_by_default(sig):
            reply(tid, r)                       # nothing to do
            return nil
        kill_process(g, sig)
        return nil
    let c = lx.getctx(tid)
    if c == nil:
        kill_process(g, 11)
        return nil
    func w(i):
        return u64(c, 8 * i)
    let rax = r
    let rip = w(15)
    if interrupted and (act[1] & SA_RESTART) != 0 and last_nr[tid] != nil:
        rax = last_nr[tid]                      # run the interrupted system call again after the handler
        rip -= 2
    let rsp = w(16)
    let top = rsp - 128
    let alt = altstk[tid]
    if (act[1] & SA_ONSTACK) != 0 and alt != nil and alt[1] > 0 and not (rsp >= alt[0] and rsp < alt[0] + alt[1]):
        top = alt[0] + alt[1]
    let F = (((top - 1104) & ~15) - 8)
    if (act[1] & SA_RESTORER) == 0:
        kill_process(g, 11)
        return nil
    let fr = []
    for i in range(1104):
        fr.append(0)
    put64(fr, 0, act[2])                       # the return address: the restorer (rt_sigreturn)
    # siginfo at 8
    put32(fr, 8, sig)
    put32(fr, 16, info.code if info != nil else 0)
    if info != nil:
        put64(fr, 24, info.addr)
    # ucontext at 136
    let uc = 136
    let sm = savedmask[tid] if savedmask[tid] != nil else (tmask[tid] ?? 0)
    # uc_stack
    if alt != nil:
        put64(fr, uc + 16, alt[0])
        put64(fr, uc + 32, alt[1])
    let g0 = uc + 40
    # gregs: r8 r9 r10 r11 r12 r13 r14 r15 rdi rsi rbp rbx rdx rax rcx rsp rip efl cs err trapno oldmask cr2
    let order = [7, 8, 9, 10, 11, 12, 13, 14, 5, 4, 6, 1, 3, 0, 2]
    for i in range(15):
        put64(fr, g0 + 8 * i, rax if order[i] == 0 else w(order[i]))
    put64(fr, g0 + 8 * 15, rsp)
    put64(fr, g0 + 8 * 16, rip)
    put64(fr, g0 + 8 * 17, w(17))
    put64(fr, g0 + 8 * 18, 0x33)
    put64(fr, g0 + 8 * 19, info.err if info != nil else 0)
    put64(fr, g0 + 8 * 20, info.trapno if info != nil else 0)
    put64(fr, g0 + 8 * 21, 0)
    put64(fr, g0 + 8 * 22, info.addr if info != nil else 0)
    put64(fr, g0 + 8 * 23, F + uc + 424)       # fpregs: points at the saved FXSAVE image
    put64(fr, uc + 296, sm)                    # uc_sigmask
    for i in range(512):
        fr[uc + 424 + i] = c[8 * 19 + i]
    if lx.write(g.pid, F, sslcore.concat([fr])) != 0:
        kill_process(g, 11)
        return nil
    savedmask[tid] = nil
    tmask[tid] = (tmask[tid] ?? 0) | act[3] | (0 if (act[1] & SA_NODEFER) != 0 else sigbit(sig))
    if (act[1] & SA_RESETHAND) != 0:
        g.sigs[sig] = nil
    put64(c, 8 * 15, h)
    put64(c, 8 * 16, F)
    put64(c, 8 * 5, sig)
    put64(c, 8 * 4, F + 8)
    put64(c, 8 * 3, F + uc)
    put64(c, 8 * 0, 0)
    put64(c, 8 * 17, w(17) & ~0x400)
    lx.setctx(tid, c)
    lx.reply(tid, 0)

# rt_sigreturn: the handler is done; take the registers back from the frame (the handler may have changed them)
func sys_rt_sigreturn(g, a):
    let c = lx.getctx(cur_tid)
    if c == nil:
        return -EFAULT
    let rsp = u64(c, 8 * 16)
    let uc = rsp + 128 - 8 + 8              # (the restorer's return popped the return-address slot: rsp = F + 8; ucontext = F + 136)
    let fr = rd(g, uc, 424 + 512)
    if fr == nil:
        kill_process(g, 11)
        return nil
    let g0 = 40
    let order = [7, 8, 9, 10, 11, 12, 13, 14, 5, 4, 6, 1, 3, 0, 2]
    for i in range(15):
        put64(c, 8 * order[i], u64(fr, g0 + 8 * i))
    put64(c, 8 * 16, u64(fr, g0 + 8 * 15))
    put64(c, 8 * 15, u64(fr, g0 + 8 * 16))
    put64(c, 8 * 17, u64(fr, g0 + 8 * 17))
    for i in range(512):
        c[8 * 19 + i] = fr[424 + i]
    tmask[cur_tid] = u64(fr, 296) & ~(sigbit(9) | sigbit(19))
    lx.setctx(cur_tid, c)
    reply(cur_tid, u64(c, 0))
    return nil

# ---- sending signals ----
func interrupt(tid):
    let f = blocked[tid]
    if f != nil:
        blocked[tid] = nil
        f()
        reply(tid, -EINTR)
        return true
    return false

func post_signal(g, tid, sig, info):
    if sig < 1 or sig > 64:
        return -EINVAL
    let act = g.sigs[sig]
    let h = act[0] if act != nil else 0
    if h == 1 or (h == 0 and sig_ignored_by_default(sig)):
        return 0                                 # ignored: discarded at once
    let target = tid
    if target == 0:
        target = g.pid
    let masked = ((tmask[target] ?? 0) & sigbit(sig)) != 0 and sig != 9 and sig != 19
    if h == 0 and not masked:
        kill_process(g, sig)                     # default action: terminate
        return 0
    if tid != 0:
        tpend[tid] = (tpend[tid] ?? 0) | sigbit(sig)
    else:
        g.pend = g.pend | sigbit(sig)
    # wake a thread that can take it: a blocked one gets EINTR, a running one is asked to report at its next timer tick
    let cand = [tid] if tid != 0 else []
    if tid == 0:
        for t in keys(g.tids):
            cand.append(t)
    for t in cand:
        if ((tmask[t] ?? 0) & sigbit(sig)) == 0 or sig == 9:
            if not interrupt(t):
                lx.sigpend(t, 1)
            return 0
    return 0

func sys_kill(g, a):
    let pid = i32(a[0])
    let sig = a[1]
    let t = guests[pid if pid > 0 else g.pid]
    if t == nil:
        return -3
    if sig == 0:
        return 0
    return post_signal(t, 0, sig, nil)

func sys_tgkill(g, a):
    let t = tmap[a[1]]
    if t == nil or t.pid != a[0]:
        return -3
    if a[2] == 0:
        return 0
    return post_signal(t, a[1], a[2], nil)

func sys_tkill(g, a):
    let t = tmap[a[0]]
    if t == nil:
        return -3
    if a[1] == 0:
        return 0
    return post_signal(t, a[0], a[1], nil)

func sys_sigaction(g, a):
    let sig = a[0]
    if sig < 1 or sig > 64 or sig == 9 or sig == 19:
        return -EINVAL
    if a[2] != 0:
        let old = g.sigs[sig]
        let b = []
        for i in range(32):
            b.append(0)
        if old != nil:
            put64(b, 0, old[0])
            put64(b, 8, old[1])
            put64(b, 16, old[2])
            put64(b, 24, old[3])
        wr(g, a[2], sslcore.concat([b]))
    if a[1] != 0:
        let act = rd(g, a[1], 32)
        if act == nil:
            return -EFAULT
        g.sigs[sig] = [u64(act, 0), u64(act, 8), u64(act, 16), u64(act, 24)]
        if u64(act, 0) == 1 or (u64(act, 0) == 0 and sig_ignored_by_default(sig)):
            g.pend = g.pend & ~sigbit(sig)
    return 0

func sys_sigprocmask(g, a):
    let old = tmask[cur_tid] ?? 0
    if a[2] != 0:
        wr(g, a[2], sslcore.concat([[(old >> 0) & 255, (old >> 8) & 255, (old >> 16) & 255, (old >> 24) & 255, (old >> 32) & 255, (old >> 40) & 255, (old >> 48) & 255, (old >> 56) & 255]]))
    if a[1] != 0:
        let sb = rd(g, a[1], 8)
        if sb == nil:
            return -EFAULT
        let set = u64(sb, 0)
        let nm = old
        if a[0] == 0:
            nm = old | set
        elif a[0] == 1:
            nm = old & ~set
        elif a[0] == 2:
            nm = set
        else:
            return -EINVAL
        tmask[cur_tid] = nm & ~(sigbit(9) | sigbit(19))
    return 0

func sys_sigaltstack(g, a):
    if a[1] != 0:
        let alt = altstk[cur_tid]
        let b = []
        for i in range(24):
            b.append(0)
        if alt != nil:
            put64(b, 0, alt[0])
            put64(b, 16, alt[1])
        else:
            put32(b, 8, 2)                       # SS_DISABLE
        wr(g, a[1], sslcore.concat([b]))
    if a[0] != 0:
        let ss = rd(g, a[0], 24)
        if ss == nil:
            return -EFAULT
        if (u32(ss, 8) & 2) != 0:
            altstk[cur_tid] = nil
        else:
            altstk[cur_tid] = [u64(ss, 0), u64(ss, 16)]
    return 0

func sys_pause(g, a):
    let tid = cur_tid
    waiters.append([tid, () => nil, 0, 0])
    blocked[tid] = () => cancel_waiter(tid)
    return nil

func cancel_waiter(tid):
    let keep = []
    for w in waiters:
        if w[0] != tid:
            keep.append(w)
    waiters = keep

func sys_sigsuspend(g, a):
    let sb = rd(g, a[0], 8)
    if sb == nil:
        return -EFAULT
    savedmask[cur_tid] = tmask[cur_tid] ?? 0
    tmask[cur_tid] = u64(sb, 0) & ~(sigbit(9) | sigbit(19))
    # a signal that was waiting for the new mask is delivered by reply(); otherwise wait
    if next_deliverable(g, cur_tid) != nil:
        return -EINTR
    return sys_pause(g, a)

func sys_sigpending(g, a):
    let p = ((tpend[cur_tid] ?? 0) | g.pend) & (tmask[cur_tid] ?? 0)
    return wr(g, a[0], sslcore.concat([[p & 255, (p >> 8) & 255, (p >> 16) & 255, (p >> 24) & 255, (p >> 32) & 255, (p >> 40) & 255, (p >> 48) & 255, (p >> 56) & 255]]))

func sys_sigtimedwait(g, a):
    let sb = rd(g, a[0], 8)
    if sb == nil:
        return -EFAULT
    let set = u64(sb, 0)
    let t = ts_ms(g, a[2])
    if t == nil:
        return -EFAULT
    let tid = cur_tid
    func check():
        let avail = ((tpend[tid] ?? 0) | g.pend) & set
        if avail == 0:
            return nil
        for sig in range(1, 65):
            if (avail & sigbit(sig)) != 0:
                if (tpend[tid] ?? 0) & sigbit(sig) != 0:
                    tpend[tid] = tpend[tid] & ~sigbit(sig)
                else:
                    g.pend = g.pend & ~sigbit(sig)
                if a[1] != 0:
                    let si = []
                    for i in range(128):
                        si.append(0)
                    put32(si, 0, sig)
                    wr(g, a[1], sslcore.concat([si]))
                return sig
        return nil
    let r = check()
    if r != nil:
        return r
    if t == 0:
        return -EAGAIN
    waiters.append([tid, check, 0 if t < 0 else psys.ms() + t, -EAGAIN])
    blocked[tid] = () => cancel_waiter(tid)
    return nil

# alarm / setitimer (ITIMER_REAL): SIGALRM
func set_alarm(g, first_ms, interval_ms):
    if first_ms <= 0:
        alarms[g.pid] = nil
    else:
        alarms[g.pid] = [psys.ms() + first_ms, interval_ms]

func sys_alarm(g, a):
    let old = alarms[g.pid]
    let left = 0
    if old != nil:
        left = imax(1, (old[0] - psys.ms() + 999) // 1000)
    set_alarm(g, a[0] * 1000, 0)
    return left

func sys_setitimer(g, a):
    if a[0] != 0:
        return -EINVAL
    if a[2] != 0:
        let old = alarms[g.pid]
        let b = []
        for i in range(32):
            b.append(0)
        if old != nil:
            let left = imax(0, old[0] - psys.ms())
            put64(b, 0, old[1] // 1000)
            put64(b, 8, (old[1] % 1000) * 1000)
            put64(b, 16, left // 1000)
            put64(b, 24, (left % 1000) * 1000)
        wr(g, a[2], sslcore.concat([b]))
    let nv = rd(g, a[1], 32)
    if nv == nil:
        return -EFAULT
    set_alarm(g, u64(nv, 16) * 1000 + u64(nv, 24) // 1000, u64(nv, 0) * 1000 + u64(nv, 8) // 1000)
    return 0

func sys_getitimer(g, a):
    let old = alarms[g.pid]
    let b = []
    for i in range(32):
        b.append(0)
    if old != nil:
        let left = imax(0, old[0] - psys.ms())
        put64(b, 0, old[1] // 1000)
        put64(b, 8, (old[1] % 1000) * 1000)
        put64(b, 16, left // 1000)
        put64(b, 24, (left % 1000) * 1000)
    return wr(g, a[1], sslcore.concat([b]))

func fire_alarms():
    if len(alarms) == 0:
        return nil
    let now = psys.ms()
    for pid in keys(alarms):
        let al = alarms[pid]
        if al != nil and al[0] <= now:
            let g = guests[pid]
            if al[1] > 0:
                alarms[pid] = [now + imax(al[1], 100), al[1]]     # (a program's 20 ms timer would eat a machine this slow: at most ten ticks a second)
            else:
                alarms[pid] = nil
            if g != nil:
                post_signal(g, 0, 14, nil)

func alarm_deadline():
    let best = 0
    for pid in alarms:
        let al = alarms[pid]
        if al != nil:
            let d = imax(1, al[0] - psys.ms())
            if best == 0 or d < best:
                best = d
    return best

# the kernel reports an exception of a program: a handler for the matching signal runs, otherwise the program ends
func serve_fault(g, tid, q):
    let vec = to_int(q[1])
    let addr = to_int(q[2])
    let err = to_int(q[3])
    let sig = 11
    if vec == 0 or vec == 16 or vec == 19:
        sig = 8
    elif vec == 6:
        sig = 4
    elif vec == 17:
        sig = 7
    let act = g.sigs[sig]
    let c = lx.getctx(tid)
    let masked = ((tmask[tid] ?? 0) & sigbit(sig)) != 0
    if act == nil or act[0] <= 1 or c == nil or masked:
        kill_process(g, sig)
        return nil
    deliver(g, tid, sig, u64(c, 0), false, {code: 1 if (err & 1) == 0 else 2, addr: addr, trapno: vec, err: err})

# the kernel asks us to look at a program that was running when a signal arrived
func serve_signal_check(g, tid):
    let c = lx.getctx(tid)
    if c == nil:
        return nil
    reply(tid, u64(c, 0))

# ================= more of the system call table (after C-OS's cos_linux.c) =================

# a path argument relative to a directory descriptor
func at_path(g, dirfd0, path, follow = true):
    let dirfd = i32(dirfd0)
    if path.starts_with("/") or dirfd == AT_FDCWD:
        return abspath(g, path) if follow else abspath_nf(g, path)
    let d = g.fds[dirfd]
    if d == nil or d.kind != "dir":
        return nil
    return resolve(norm(d.path .. "/" .. path), follow)

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
    let p = at_path(g, a[0], path, false)
    if p == nil:
        return -EBADF
    try:
        links_changed()
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
    let x = at_path(g, a[0], p1, false)
    let y = at_path(g, a[2], p2, false)
    links_changed()
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
    let p = at_path(g, a[0], path, false)
    if p == nil:
        return -EBADF
    return readlink_path(g, p, a[2], a[3])

func readlink_path(g, p, buf, size):
    if p == "/proc/self/exe":
        let b = sslcore.from_str(g.exe)
        let n = imin(len(b), size)
        let r = wr(g, buf, b.slice(0, n))
        return r if r < 0 else n
    if p.starts_with("/proc/self/fd/"):
        let ff = g.fds[to_int(p.slice(14))]
        if ff == nil:
            return -ENOENT
        let tgt = ff.path if (ff.kind == "file" or ff.kind == "dir" or ff.kind == "mem") else ("pipe:[" .. to_string(len(ff.kind)) .. "]" if ff.kind == "pipe" else ("socket:[1]" if ff.kind == "sock" else "/dev/null"))
        let tb = sslcore.from_str(tgt)
        let n2 = imin(len(tb), size)
        let r2 = wr(g, buf, tb.slice(0, n2))
        return r2 if r2 < 0 else n2
    if not p.starts_with("/proc"):
        let tt = nil
        try:
            tt = fs.readlink(p)
        catch e:
            return -errno_of(e.kind) if e.kind != "EINVAL" else -EINVAL
        let tb2 = sslcore.from_str(tt)
        let n3 = imin(len(tb2), size)
        let r3 = wr(g, buf, tb2.slice(0, n3))
        return r3 if r3 < 0 else n3
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


# block the calling thread until check() gives a result (not nil), or the timeout; timeout_ms < 0: for ever, 0: do not wait
func block(check, timeout_ms, tres):
    let r = check()
    if r != nil:
        return r
    if timeout_ms == 0:
        return tres
    waiters.append([cur_tid, check, 0 if timeout_ms < 0 else psys.ms() + timeout_ms, tres])
    let tid = cur_tid
    blocked[tid] = () => cancel_waiter(tid)
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
            reply(w[0], r)
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
    if k == "timerfd":
        timerfd_update(f)
        return POLLIN if f.count > 0 else 0
    if k == "epoll":
        return POLLIN if len(epoll_ready(f, 1)) > 0 else 0
    if k == "sock":
        return sock_ready(f)
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


# ---- timerfd: a descriptor that becomes readable when its timer expires (GLib/WebKit use it for their timeouts) ----
let timerfds = []

func sys_timerfd_create(g, a):
    let f = {kind: "timerfd", expire: 0, interval: 0, count: 0, nonblock: (a[1] & 0o4000) != 0}
    timerfds.append(f)
    return g.alloc_fd(f)

# fold the expirations that happened into the count
func timerfd_update(f):
    if f.expire == 0:
        return nil
    let now = now_us()
    if f.expire <= now:
        if f.interval > 0:
            let n = 1 + (now - f.expire) // f.interval
            f.count += n
            f.expire += n * f.interval
        else:
            f.count += 1
            f.expire = 0

# milliseconds until the earliest armed timer fires (0: none)
func timerfd_deadline():
    let best = 0
    for f in timerfds:
        if f.expire != 0:
            let d = imax(1, (f.expire - now_us() + 999) // 1000)
            if best == 0 or d < best:
                best = d
    return best

func timerfd_spec(g, addr, interval_us, value_us):
    let b = []
    for i in range(32):
        b.append(0)
    put64(b, 0, interval_us // 1000000)
    put64(b, 8, (interval_us % 1000000) * 1000)
    put64(b, 16, value_us // 1000000)
    put64(b, 24, (value_us % 1000000) * 1000)
    return wr(g, addr, sslcore.concat([b]))

func sys_timerfd_settime(g, a):
    let f = g.fds[i32(a[0])]
    if f == nil or f.kind != "timerfd":
        return -EBADF
    let raw = rd(g, a[2], 32)
    if raw == nil:
        return -EFAULT
    if a[3] != 0:
        timerfd_update(f)
        let left = imax(0, f.expire - now_us()) if f.expire != 0 else 0
        let e = timerfd_spec(g, a[3], f.interval, left)
        if e < 0:
            return e
    let interval = u64(raw, 0) * 1000000 + u64(raw, 8) // 1000
    let value = u64(raw, 16) * 1000000 + u64(raw, 24) // 1000
    f.count = 0
    if value == 0:
        f.expire = 0
        f.interval = 0
    else:
        f.expire = value if (a[1] & 1) != 0 else now_us() + value
        f.interval = interval
    return 0

func sys_timerfd_gettime(g, a):
    let f = g.fds[i32(a[0])]
    if f == nil or f.kind != "timerfd":
        return -EBADF
    timerfd_update(f)
    return timerfd_spec(g, a[1], f.interval, imax(0, f.expire - now_us()) if f.expire != 0 else 0)

func timerfd_read(g, f, buf):
    func check():
        timerfd_update(f)
        if f.count == 0:
            return nil
        let b = []
        for i in range(8):
            b.append(0)
        put64(b, 0, f.count)
        f.count = 0
        wr(g, buf, sslcore.concat([b]))
        return 8
    return block(check, 0 if f.nonblock else -1, -11)

func eventfd_write(g, f, b):
    if len(b) < 8:
        return -EINVAL
    f.count += u64(b, 0)
    return 8




# ================= /proc and /dev (generated when opened) =================
func maps_text(g):
    let lines = []
    let regs = []
    for r in g.vm:
        regs.append(r)
    regs.sort((x, y) => x[0] < y[0])
    for r in regs:
        let pr = ("r" if (r[2] & 4) != 0 else "-") .. ("w" if (r[2] & 2) != 0 else "-") .. ("x" if (r[2] & 1) != 0 else "-") .. "p"
        let line = padn(hexn(r[0]), 8) .. "-" .. padn(hexn(r[1]), 8) .. " " .. pr .. " 00000000 00:00 0"
        if r[3] != "":
            while len(line) < 73:
                line = line .. " "
            line = line .. r[3]
        lines.append(line)
    return lines.join("\n") .. "\n"

func base_name(p):
    let i = last_slash(p)
    return p.slice(i + 1)

func fmt_us(us):
    return to_string(us // 1000000) .. "." .. padn(to_string((us % 1000000) // 10000), 2)

func proc_text(g, path):
    let rest = path
    if path.starts_with("/proc/self/"):
        rest = path.slice(10)
    elif path.starts_with("/proc/" .. to_string(g.pid) .. "/"):
        rest = path.slice(6 + len(to_string(g.pid)))
    else:
        rest = nil
    if rest == "/maps":
        return maps_text(g)
    if rest == "/cmdline":
        let t = ""
        for a in g.argv:
            t = t .. a .. "\0"
        return t
    if rest == "/environ":
        let t = ""
        for a in g.envp:
            t = t .. a .. "\0"
        return t
    if rest == "/comm":
        return base_name(g.exe) .. "\n"
    if rest == "/status":
        let nm = base_name(g.exe)
        return "Name:\t" .. nm .. "\nState:\tR (running)\nTgid:\t" .. to_string(g.pid) .. "\nPid:\t" .. to_string(g.pid) .. "\nPPid:\t" .. to_string(g.parent if g.parent != 0 else 1) .. "\nUid:\t0\t0\t0\t0\nGid:\t0\t0\t0\t0\nThreads:\t" .. to_string(g.nthreads) .. "\nVmPeak:\t   20000 kB\nVmSize:\t   20000 kB\nVmRSS:\t    8000 kB\nSigQ:\t0/1024\nCpus_allowed:\t1\nCpus_allowed_list:\t0\n"
    if rest == "/stat":
        let nm = base_name(g.exe)
        let f = [to_string(g.pid), "(" .. nm .. ")", "R", to_string(g.parent if g.parent != 0 else 1), to_string(g.pid), to_string(g.pid), "0", "-1", "0", "0", "0", "0", "0", "0", "0", "0", "0", "20", "0", to_string(g.nthreads), "0", "0", "20000000", "2000", "18446744073709551615"]
        while len(f) < 52:
            f.append("0")
        return f.join(" ") .. "\n"
    if rest == "/limits":
        return "Limit                     Soft Limit           Hard Limit           Units     \nMax stack size            8388608              unlimited            bytes     \nMax open files            1024                 4096                 files     \n"
    if path == "/proc/cpuinfo":
        return "processor\t: 0\nvendor_id\t: SprintOS\ncpu family\t: 6\nmodel\t\t: 1\nmodel name\t: SprintOS virtual CPU\ncpu MHz\t\t: 2000.000\ncache size\t: 1024 KB\nphysical id\t: 0\nsiblings\t: 1\ncore id\t\t: 0\ncpu cores\t: 1\nflags\t\t: fpu tsc msr pae cx8 apic sep cmov pat mmx fxsr sse sse2 syscall nx lm\nbogomips\t: 4000.00\nclflush size\t: 64\naddress sizes\t: 40 bits physical, 48 bits virtual\n\n"
    if path == "/proc/meminfo":
        return "MemTotal:       262144 kB\nMemFree:        131072 kB\nMemAvailable:   131072 kB\nBuffers:            0 kB\nCached:         16384 kB\nSwapTotal:          0 kB\nSwapFree:           0 kB\n"
    if path == "/proc/version":
        return "Linux version 6.1.0-sprintos (sprint@sprintos) (Sprint) #1 SMP SprintOS\n"
    if path == "/proc/uptime":
        return fmt_us(psys.ms() * 1000) .. " " .. fmt_us(psys.ms() * 500) .. "\n"
    if path == "/proc/loadavg":
        return "0.00 0.00 0.00 1/" .. to_string(len(guests) + 1) .. " " .. to_string(g.pid) .. "\n"
    if path == "/proc/stat":
        return "cpu  100 0 100 10000 0 0 0 0 0 0\ncpu0 100 0 100 10000 0 0 0 0 0 0\nbtime 1700000000\n"
    if path == "/proc/sys/vm/overcommit_memory":
        return "1\n"
    if path == "/proc/sys/kernel/pid_max":
        return "32768\n"
    if path == "/proc/sys/kernel/random/boot_id":
        return "00000000-0000-0000-0000-000000000001\n"
    return nil

# directories that exist only here: names of their entries
func vdir_names(g, path):
    if path == "/proc":
        return ["self", "cpuinfo", "meminfo", "version", "uptime", "loadavg", "stat", "sys", to_string(g.pid)]
    if path == "/proc/self" or path == "/proc/" .. to_string(g.pid):
        return ["maps", "cmdline", "environ", "comm", "status", "stat", "limits", "fd", "cwd", "exe"]
    if path == "/proc/self/fd" or path == "/proc/" .. to_string(g.pid) .. "/fd":
        let out = []
        for fd in keys(g.fds):
            if g.fds[fd] != nil:
                out.append(to_string(fd))
        return out
    if path == "/proc/sys" or path == "/proc/sys/vm" or path == "/proc/sys/kernel":
        return ["vm", "kernel"] if path == "/proc/sys" else (["overcommit_memory"] if path == "/proc/sys/vm" else ["pid_max", "random"])
    if path == "/dev":
        return ["null", "zero", "urandom", "random", "tty", "console", "stdin", "stdout", "stderr", "fd"]
    return nil

# open a generated file or directory: an fd, or nil when the path is not one of ours
func open_virtual(g, p):
    let names = vdir_names(g, p)
    if names != nil:
        let ents = [{kind: "dir", name: "."}, {kind: "dir", name: ".."}]
        for n in names:
            ents.append({kind: "dir" if (n == "self" or n == "fd" or n == "sys" or n == "vm" or n == "kernel" or n == "random" or n == to_string(g.pid)) else "file", name: n})
        return g.alloc_fd({kind: "dir", path: p, pos: 0, names: ents, virtual: true})
    if p.starts_with("/proc/"):
        let t = proc_text(g, p)
        if verbose == "trace":
            log("proc " .. p .. " -> " .. to_string(len(t) if t != nil else -1) .. " bytes")
        if t == nil:
            return -ENOENT
        return g.alloc_fd({kind: "mem", path: p, pos: 0, data: sslcore.from_str(t), readable: true, writable: false, append: false})
    return nil

func virtual_stat_kind(g, p):
    if vdir_names(g, p) != nil:
        return "dir"
    if p.starts_with("/proc/") and proc_text(g, p) != nil:
        return "file"
    if p == "/proc/self/exe" or p == "/proc/self/cwd":
        return "symlink"
    return nil



# ================= the network: TCP/IP stack (netstack) over netd's frame interface =================
const EINPROGRESS = 115
const ETIMEDOUT = 110
const ECONNRESET = 104

let net = nil              # {link, st} once the stack is up
let net_failed = false
let extra_inbox = []       # messages that arrived while the stack waited for netd (DHCP): the main loop serves them first

# netstack's link over netd: frames come in as "rx" notices, go out through the shared segment; nothing here blocks the server except the DHCP at start
class PushLink:
    let pid = 0
    let seg = nil
    let va = 0
    let mac = nil
    let rxq = nil
    let txq = nil
    let tx_busy = false
    let sync_wait = false
    func init(self):
        self.pid = ipc.lookup("net")
        if self.pid == nil or self.pid <= 0:
            throw error("ENODEV", "no netd")
        self.rxq = []
        self.txq = []
        self.seg = ipc.shm_create(4096)
        self.va = self.seg[1]
        ipc.send(self.pid, "sub\t" .. to_string(self.seg[0]))
        while true:
            let m = ipc.recv_from()
            if m[0] != self.pid:
                extra_inbox.append(m)
                continue
            let q = m[1].split("\t")
            if q[0] == "ok":
                let h = q[1].split(":")
                self.mac = h.map(x => hexbyte(x))
                break
            if q[0] == "err":
                throw error("ENODEV", q[1])
    func send(self, f):
        self.txq.append(f)
        self.pump_tx()
    func pump_tx(self):
        if self.tx_busy or len(self.txq) == 0:
            return nil
        let f = self.txq.remove_at(0)
        for i in range(len(f)):
            uio.poke8(self.va + 2048 + i, f[i])
        self.tx_busy = true
        ipc.send(self.pid, "tx\t" .. to_string(len(f)))
    func on_msg(self, text):
        let q = text.split("\t")
        if q[0] == "rx":
            let n = to_int(q[1])
            let f = []
            f.reserve(n)
            for i in range(n):
                f.append(uio.peek8(self.va + i))
            ipc.send(self.pid, "ack")
            if len(self.rxq) < 256:
                self.rxq.append(f)
        elif q[0] == "ok" or q[0] == "err":
            self.tx_busy = false
            self.pump_tx()
    # during the DHCP at start the call may wait; later it only hands over what has arrived
    func recv(self, ms):
        if len(self.rxq) > 0:
            return self.rxq.remove_at(0)
        if not self.sync_wait or ms <= 0:
            return nil
        let m = ipc.recv_from(true, ms)
        if m == nil:
            return nil
        if m[0] == self.pid:
            self.on_msg(m[1])
        else:
            extra_inbox.append(m)
        if len(self.rxq) > 0:
            return self.rxq.remove_at(0)
        return nil

func hexbyte(h):
    let v = 0
    for i in range(len(h)):
        let c = h[i]
        v = v * 16 + (c - 48 if c <= 57 else c - 87)
    return v

func net_up():
    if net != nil:
        return true
    if net_failed:
        return false
    try:
        let link = PushLink()
        let st = netstack.Stack(link, psys.ms, link.mac)
        link.sync_wait = true
        let ok = st.dhcp(6000)
        link.sync_wait = false
        if not ok:
            log("network: no DHCP answer")
            net_failed = true
            return false
        st.async_mode = true
        net = {link: link, st: st}
        log("network up: " .. netstack.ip_str(st.ip) .. " gateway " .. netstack.ip_str(st.gw) .. " dns " .. netstack.ip_str(st.dns))
        return true
    catch e:
        net_failed = true
        return false

# frames from netd, timers
func net_message(text):
    net.link.on_msg(text)
    net_pump()

func net_pump():
    if net == nil:
        return nil
    let l = net.link
    while len(l.rxq) > 0:
        net.st.rx_frame(l.rxq.remove_at(0))
    net.st.timers()
    l.pump_tx()

func net_deadline():
    if net == nil:
        return 0
    if len(net.st.conns) > 0 or len(net.st.arp_wait) > 0:
        return 40
    return 0

func to_typed(a):
    return sslcore.concat([a])

func ip_to_str(v):
    return netstack.ip_str(v)

# connect (TCP): start the handshake; wait for it unless the socket is nonblocking
func net_connect(g, f, sa):
    if sa[0] != "inet" or not net_up():
        return -ENETUNREACH
    let c = net.st.tcp_connect_start(sa[1], sa[2])
    f.conn = c
    f.state = "connecting"
    f.name = "inet"
    f.port = c.lport
    f.peer_ip = sa[1]
    f.peer_port = sa[2]
    net_pump()
    if f.nonblock:
        return -EINPROGRESS
    func check():
        net_pump()
        if c.state == "ESTABLISHED":
            f.state = "connected"
            return 0
        if c.state == "CLOSED":
            f.state = "new"
            f.conn = nil
            return -ETIMEDOUT if c.err == "timed out" else -ECONNREFUSED
        return nil
    return block(check, -1, -ETIMEDOUT)

func net_tcp_send(g, f, data, nonblock):
    let c = f.conn
    let sent = {n: 0}
    func check():
        net_pump()
        if c.state != "ESTABLISHED" and c.state != "CLOSE_WAIT":
            return -EPIPE if sent.n == 0 else sent.n
        let rest = data if sent.n == 0 else data.slice(sent.n)
        let n = net.st.tcp_send_nb(c, rest.to_array())
        if n < 0:
            return -EPIPE if sent.n == 0 else sent.n
        sent.n += n
        net_pump()
        if sent.n >= len(data):
            return sent.n
        return nil
    let r = check()
    if r != nil:
        return r
    if nonblock:
        return sent.n if sent.n > 0 else -EAGAIN
    return block(check, -1, -EAGAIN)

func net_tcp_recv(f, n, peek):
    net_pump()
    let c = f.conn
    if peek:
        if len(c.rbuf) > 0:
            return to_typed(c.rbuf.slice(0, imin(n, len(c.rbuf))))
    else:
        try:
            let r = net.st.tcp_recv_nb(c, n)
            if r == nil:
                return nil
            return to_typed(r)
        catch e:
            return -ECONNRESET
    if c.fin_rcvd or c.state == "CLOSED":
        return sslcore.concat([[]])
    return nil

func net_udp_socket(f):
    if f.usock == nil:
        f.usock = net.st.udp_open(f.port)
        f.port = f.usock.port
    return f.usock

func net_udp_send(f, data, ip, port):
    let u = net_udp_socket(f)
    net.st.udp_send(u, ip, port, data.to_array())
    net_pump()
    return len(data)

func net_is_ip_local(v):
    return (v >> 24) == 127

func net_sock_ready(f):
    net_pump()
    if f.tl != nil:
        return POLLIN if len(f.tl.queue) > 0 else 0
    if f.usock != nil:
        return (POLLIN if len(f.usock.queue) > 0 else 0) | POLLOUT
    let c = f.conn
    if c == nil:
        return 0
    if f.state == "connecting":
        if c.state == "ESTABLISHED":
            f.state = "connected"
        elif c.state == "CLOSED":
            return POLLOUT | POLLERR | POLLHUP
        else:
            return 0
    let r = 0
    if len(c.rbuf) > 0:
        r = POLLIN
    if c.fin_rcvd or c.state == "CLOSED":
        r = r | POLLIN | POLLHUP
    if (c.state == "ESTABLISHED" or c.state == "CLOSE_WAIT") and net.st.tcp_space(c) > 0:
        r = r | POLLOUT
    return r

func net_sock_close(f):
    if net == nil:
        return nil
    if f.conn != nil:
        if f.conn.state == "ESTABLISHED" or f.conn.state == "CLOSE_WAIT":
            net.st.tcp_close_nb(f.conn)
        else:
            net.st.tcp_close_nb(f.conn)
    if f.tl != nil:
        net.st.tcp_unlisten(f.tl)
    if f.usock != nil:
        net.st.udp_close(f.usock)
    net_pump()


# ================= sockets: AF_UNIX and loopback (in this process; the network ones come later) =================

let unix_names = {}      # path -> listening / bound socket
let inet_ports = {}      # port -> listening / bound socket (loopback)
let next_port = 40000

func new_sock(domain, type, flags):
    return {kind: "sock", domain: domain, type: type & 15, nonblock: (type & 0x800) != 0, state: "new", name: nil, port: 0, backlog: [], peer: nil,
            data: [], size: 0, msgs: [], eof: false, shut_wr: false, shut_rd: false, opts: {}}

func sock_of(g, fd):
    let f = g.fds[i32(fd)]
    if f == nil or f.kind != "sock":
        return nil
    return f

func sock_ready(f):
    if f.conn != nil or f.usock != nil or f.tl != nil:
        let nr = net_sock_ready(f)
        if f.tl != nil and len(f.backlog) > 0:
            nr = nr | POLLIN
        if f.usock != nil and len(f.msgs) > 0:
            nr = nr | POLLIN
        return nr
    if f.state == "listening":
        return POLLIN if len(f.backlog) > 0 else 0
    if f.type == 2:
        return (POLLIN if len(f.msgs) > 0 else 0) | POLLOUT
    let r = 0
    if f.size > 0 or f.eof or f.shut_rd:
        r = POLLIN
    if f.eof:
        r = r | POLLHUP | POLLIN
    if f.state == "connected":
        r = r | POLLOUT
    if f.state == "new":
        r = r | POLLOUT | POLLHUP
    return r

func sock_close(f):
    if f.conn != nil or f.usock != nil or f.tl != nil:
        net_sock_close(f)
    if f.name != nil:
        if f.domain == AF_UNIX and unix_names[f.name] == f:
            unix_names[f.name] = nil
        if f.domain != AF_UNIX and inet_ports[f.port] == f:
            inet_ports[f.port] = nil
    let p = f.peer
    if p != nil:
        p.eof = true
        p.peer = nil
    for c in f.backlog:           # connections that were never accepted
        if c.peer != nil:
            c.peer.eof = true
            c.peer.peer = nil
    f.state = "closed"

# a sockaddr from the program's memory: ["unix", path] or ["inet", ip (int), port]
func read_sockaddr(g, addr, alen):
    if alen < 2:
        return nil
    let b = rd(g, addr, imin(alen, 128))
    if b == nil:
        return nil
    let fam = u16(b, 0)
    if fam == AF_UNIX:
        let stop = 2
        if len(b) > 2 and b[2] == 0:                  # abstract
            return ["unix", "@" .. sslcore.to_text(b.slice(3))]
        while stop < len(b) and b[stop] != 0:
            stop += 1
        return ["unix", sslcore.to_text(b.slice(2, stop))]
    if fam == AF_INET and len(b) >= 8:
        return ["inet", (b[4] << 24) | (b[5] << 16) | (b[6] << 8) | b[7], (b[2] << 8) | b[3]]
    if fam == AF_INET6 and len(b) >= 24:
        let port = (b[2] << 8) | b[3]
        let loop = true
        for i in range(8, 23):
            if b[i] != 0:
                loop = false
        if loop and b[23] == 1:
            return ["inet", 0x7f000001, port]
        let mapped = true
        for i in range(8, 18):
            if b[i] != 0:
                mapped = false
        if mapped and b[18] == 255 and b[19] == 255:
            return ["inet", (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23], port]
        return ["inet6", 0, port]
    return nil

func u16le(v):
    return [v & 255, (v >> 8) & 255]

func sockaddr_bytes(f, local):
    if f.conn != nil and f.domain != AF_UNIX:
        let ip = (net.st.ip if net != nil else 0) if local else f.peer_ip
        let prt = f.conn.lport if local else f.peer_port
        if f.domain == AF_INET6:
            let b = []
            for i in range(28):
                b.append(0)
            put16(b, 0, AF_INET6)
            b[2] = (prt >> 8) & 255
            b[3] = prt & 255
            b[18] = 255
            b[19] = 255
            b[20] = (ip >> 24) & 255
            b[21] = (ip >> 16) & 255
            b[22] = (ip >> 8) & 255
            b[23] = ip & 255
            return sslcore.concat([b])
        return sslcore.concat([u16le(AF_INET), [(prt >> 8) & 255, prt & 255, (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255], [0, 0, 0, 0, 0, 0, 0, 0]])
    let other = f if local else f.peer
    if other == nil:
        return sslcore.concat([u16le(f.domain)])
    if f.domain == AF_UNIX:
        if other.name == nil:
            return sslcore.concat([u16le(AF_UNIX)])
        return sslcore.concat([u16le(AF_UNIX), sslcore.from_str(other.name), [0]])
    let port = other.port
    if f.domain == AF_INET6:
        let b = []
        for i in range(28):
            b.append(0)
        put16(b, 0, AF_INET6)
        b[2] = (port >> 8) & 255
        b[3] = port & 255
        b[23] = 1
        return sslcore.concat([b])
    return sslcore.concat([u16le(AF_INET), [(port >> 8) & 255, port & 255, 127, 0, 0, 1], [0, 0, 0, 0, 0, 0, 0, 0]])

func put_sockaddr(g, f, local, addr, lenptr):
    if addr == 0 or lenptr == 0:
        return 0
    let sa = sockaddr_bytes(f, local)
    let lb = rd(g, lenptr, 4)
    if lb == nil:
        return -EFAULT
    let n = imin(u32(lb, 0), len(sa))
    if n > 0:
        wr(g, addr, sa.slice(0, n))
    let ob = []
    for i in range(4):
        ob.append((len(sa) >> (8 * i)) & 255)
    wr(g, lenptr, sslcore.concat([ob]))
    return 0

func sys_socket(g, a):
    if a[0] != AF_UNIX and a[0] != AF_INET and a[0] != AF_INET6:
        return -EAFNOSUPPORT
    let t = a[1] & 15
    if t != 1 and t != 2:
        return -93
    return g.alloc_fd(new_sock(a[0], a[1], 0))

func sys_socketpair(g, a):
    if a[0] != AF_UNIX:
        return -EAFNOSUPPORT
    let x = new_sock(AF_UNIX, a[1], 0)
    let y = new_sock(AF_UNIX, a[1], 0)
    x.peer = y
    y.peer = x
    x.state = "connected"
    y.state = "connected"
    let fa = g.alloc_fd(x)
    let fb = g.alloc_fd(y)
    let b = []
    for i in range(8):
        b.append(0)
    put32(b, 0, fa)
    put32(b, 4, fb)
    return wr(g, a[3], sslcore.concat([b]))

func sys_bind(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    let sa = read_sockaddr(g, a[1], a[2])
    if sa == nil:
        return -EINVAL
    if sa[0] == "unix":
        if unix_names[sa[1]] != nil:
            return -EADDRINUSE
        unix_names[sa[1]] = f
        f.name = sa[1]
    else:
        let port = sa[2]
        if port == 0:
            port = next_port
            next_port += 1
        if inet_ports[port] != nil:
            return -EADDRINUSE
        inet_ports[port] = f
        f.port = port
        f.name = "inet"
        f.bind_ip = sa[1]
        if f.type == 2 and net != nil and not net_is_ip_local(sa[1]):
            net_udp_socket(f)
    f.state = "bound"
    return 0

func sys_listen(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    if f.type != 1:
        return -95
    if f.name == nil:                # listen without bind: an ephemeral port
        f.port = next_port
        next_port += 1
        inet_ports[f.port] = f
        f.name = "inet"
    f.state = "listening"
    f.opts.backlog = imax(1, a[1])
    if f.domain != AF_UNIX and net != nil and not net_is_ip_local(f.bind_ip ?? 0):
        f.tl = net.st.tcp_listen(f.port)
    return 0

func connect_loopback(g, f, target):
    if target == nil or target.state != "listening":
        return -ECONNREFUSED
    if len(target.backlog) >= target.opts.backlog + 1:
        return -ECONNREFUSED
    let srv = new_sock(target.domain, 1, 0)
    srv.state = "connected"
    srv.name = target.name
    srv.port = target.port
    srv.peer = f
    f.peer = srv
    f.state = "connected"
    if f.name == nil and f.domain != AF_UNIX:
        f.port = next_port
        next_port += 1
        f.name = "inet"
    target.backlog.append(srv)
    return 0

func sys_connect(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    let sa = read_sockaddr(g, a[1], a[2])
    if sa == nil:
        return -EINVAL
    if f.state == "connected":
        return -EISCONN
    if f.state == "connecting":
        net_sock_ready(f)
        return 0 if f.state == "connected" else -114
    if f.type == 2:
        f.opts.dest = sa          # a datagram socket just remembers where to send
        f.state = "connected"
        return 0
    if sa[0] == "unix":
        return connect_loopback(g, f, unix_names[sa[1]])
    if sa[0] == "inet" and (sa[1] >> 24) == 127:
        return connect_loopback(g, f, inet_ports[sa[2]])
    return net_connect(g, f, sa)

func sys_accept(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    if f.state != "listening":
        return -EINVAL
    let nb = f.nonblock or (a[3] & 0x800) != 0
    func check():
        if f.tl != nil:
            net_pump()
            if len(f.tl.queue) > 0 and len(f.backlog) == 0:
                let nc = f.tl.queue.remove_at(0)
                let ns = new_sock(f.domain, 1, 0)
                ns.state = "connected"
                ns.conn = nc
                ns.name = "inet"
                ns.port = nc.lport
                ns.peer_ip = nc.rip
                ns.peer_port = nc.rport
                f.backlog.append(ns)
        if len(f.backlog) == 0:
            return nil
        let c = f.backlog.remove_at(0)
        c.nonblock = (a[3] & 0x800) != 0
        let fd = g.alloc_fd(c)
        if a[1] != 0:
            put_sockaddr(g, c, false, a[1], a[2])
        return fd
    return block(check, 0 if nb else -1, -EAGAIN)

func sys_accept3(g, a):
    return sys_accept(g, [a[0], a[1], a[2], 0])

func sock_send(g, f, data, flags, dest):
    if f.conn != nil:
        return net_tcp_send(g, f, data, f.nonblock or (flags & 0x40) != 0)
    if f.type == 2:
        let d = dest if dest != nil else f.opts.dest
        if d == nil:
            return -89
        if d[0] == "inet" and not net_is_ip_local(d[1]):
            if not net_up():
                return -ENETUNREACH
            return net_udp_send(f, data, d[1], d[2])
        let target = nil
        if d[0] == "unix":
            target = unix_names[d[1]]
        elif d[0] == "inet":
            target = inet_ports[d[2]]
        if target == nil or target.type != 2:
            return -ECONNREFUSED
        target.msgs.append([data, f.name])
        return len(data)
    if f.state != "connected":
        return -ENOTCONN
    if f.shut_wr or f.peer == nil:
        return -EPIPE
    f.peer.data.append(data)
    f.peer.size += len(data)
    return len(data)

func sock_take(f, n):
    let all = sslcore.concat(f.data)
    let out = all.slice(0, n)
    let rest = all.slice(n)
    f.data = [rest] if len(rest) > 0 else []
    f.size = len(rest)
    return out

# bytes, an errno, or nil when the caller has to wait
func sock_recv_check(f, n, peek):
    if f.conn != nil:
        return net_tcp_recv(f, n, peek)
    if f.type == 2:
        if f.usock != nil:
            net_pump()
            if len(f.usock.queue) > 0 and len(f.msgs) == 0:
                let dgram = f.usock.queue.remove_at(0)
                f.msgs.append([to_typed(dgram[2]), nil])
                f.last_src = [dgram[0], dgram[1]]
        if len(f.msgs) == 0:
            return nil
        let m = f.msgs[0]
        if not peek:
            f.msgs.remove_at(0)
        return m[0].slice(0, imin(n, len(m[0])))
    if f.size > 0:
        if peek:
            return sslcore.concat(f.data).slice(0, imin(n, f.size))
        return sock_take(f, imin(n, f.size))
    if f.eof or f.shut_rd or f.state == "closed":
        return sslcore.concat([[]])
    if f.state != "connected":
        return -ENOTCONN
    return nil

func sys_sendto(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    let data = rd(g, a[1], a[2])
    if data == nil:
        return -EFAULT
    let dest = read_sockaddr(g, a[4], a[5]) if a[4] != 0 else nil
    return sock_send(g, f, data, a[3], dest)

func sys_recvfrom(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    let nb = f.nonblock or (a[3] & 0x40) != 0
    let peek = (a[3] & 2) != 0
    func check():
        let r = sock_recv_check(f, a[2], peek)
        if r == nil:
            return nil
        if type(r) == "int":
            return r
        if len(r) > 0:
            let e = wr(g, a[1], r)
            if e < 0:
                return e
        if a[4] != 0 and a[5] != 0:
            if f.type == 2 and f.usock != nil and f.last_src != nil:
                let ip = f.last_src[0]
                let pt = f.last_src[1]
                let sa = sslcore.concat([u16le(AF_INET), [(pt >> 8) & 255, pt & 255, (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255], [0, 0, 0, 0, 0, 0, 0, 0]])
                let lb = rd(g, a[5], 4)
                if lb != nil:
                    wr(g, a[4], sa.slice(0, imin(u32(lb, 0), 16)))
                    wr(g, a[5], sslcore.concat([[16, 0, 0, 0]]))
            else:
                put_sockaddr(g, f, false, a[4], a[5])
        return len(r)
    return block(check, 0 if nb else -1, -EAGAIN)

# msghdr: name(8) namelen(4)+pad iov(8) iovlen(8) control(8) controllen(8) flags(4)
func sys_sendmsg(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    let mh = rd(g, a[1], 56)
    if mh == nil:
        return -EFAULT
    let iov = u64(mh, 16)
    let parts = []
    for i in range(u64(mh, 24)):
        let e = rd(g, iov + i * 16, 16)
        if e == nil:
            return -EFAULT
        if u64(e, 8) > 0:
            let d = rd(g, u64(e, 0), u64(e, 8))
            if d == nil:
                return -EFAULT
            parts.append(d)
    let dest = read_sockaddr(g, u64(mh, 0), u32(mh, 8)) if u64(mh, 0) != 0 else nil
    return sock_send(g, f, sslcore.concat(parts), a[2], dest)

func sys_recvmsg(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    let mh = rd(g, a[1], 56)
    if mh == nil:
        return -EFAULT
    let iov = u64(mh, 16)
    let nb = f.nonblock or (a[2] & 0x40) != 0
    let total = 0
    let sizes = []
    for i in range(u64(mh, 24)):
        let e = rd(g, iov + i * 16, 16)
        if e == nil:
            return -EFAULT
        sizes.append([u64(e, 0), u64(e, 8)])
        total += u64(e, 8)
    func check():
        let r = sock_recv_check(f, total, (a[2] & 2) != 0)
        if r == nil:
            return nil
        if type(r) == "int":
            return r
        let off = 0
        for s in sizes:
            if off >= len(r):
                break
            let k = imin(s[1], len(r) - off)
            wr(g, s[0], r.slice(off, off + k))
            off += k
        if u64(mh, 0) != 0:                                               # msg_name: who sent it
            let sa = nil
            if f.type == 2 and f.usock != nil and f.last_src != nil:
                let ip = f.last_src[0]
                let pt = f.last_src[1]
                sa = sslcore.concat([u16le(AF_INET), [(pt >> 8) & 255, pt & 255, (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255], [0, 0, 0, 0, 0, 0, 0, 0]])
            elif f.peer != nil or f.conn != nil:
                sa = sockaddr_bytes(f, false)
            if sa != nil:
                wr(g, u64(mh, 0), sa.slice(0, imin(u32(mh, 8), len(sa))))
                wr(g, a[1] + 8, sslcore.concat([[len(sa), 0, 0, 0]]))
            else:
                wr(g, a[1] + 8, sslcore.concat([[0, 0, 0, 0]]))
        wr(g, a[1] + 40, sslcore.concat([[0, 0, 0, 0, 0, 0, 0, 0]]))     # controllen = 0
        wr(g, a[1] + 48, sslcore.concat([[0, 0, 0, 0]]))                  # flags
        return len(r)
    return block(check, 0 if nb else -1, -EAGAIN)

func sys_shutdown(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    if f.state != "connected":
        return -ENOTCONN
    if a[1] == 1 or a[1] == 2:
        f.shut_wr = true
        if f.peer != nil:
            f.peer.eof = true
    if a[1] == 0 or a[1] == 2:
        f.shut_rd = true
    return 0

func sys_getsockname(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    return put_sockaddr(g, f, true, a[1], a[2])

func sys_getpeername(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    if f.peer == nil:
        return -ENOTCONN
    return put_sockaddr(g, f, false, a[1], a[2])

func sys_setsockopt(g, a):
    return 0 if sock_of(g, a[0]) != nil else -EBADF

func sys_getsockopt(g, a):
    let f = sock_of(g, a[0])
    if f == nil:
        return -EBADF
    let v = 0
    if a[1] == 1 and a[2] == 3:           # SO_TYPE
        v = f.type
    elif a[1] == 1 and (a[2] == 7 or a[2] == 8):     # SO_SNDBUF, SO_RCVBUF
        v = 212992
    elif a[1] == 1 and a[2] == 4:                    # SO_ERROR: the result of a nonblocking connect
        if f.conn != nil and f.state == "connecting":
            net_sock_ready(f)
        if f.conn == nil and f.state == "new" and f.peer_ip != nil:
            v = ECONNREFUSED
        elif f.conn != nil and f.conn.state == "CLOSED" and f.state == "connecting":
            v = ETIMEDOUT if f.conn.err == "timed out" else ECONNREFUSED
    if a[3] != 0:
        let b = []
        for i in range(4):
            b.append((v >> (8 * i)) & 255)
        wr(g, a[3], sslcore.concat([b]))
        if a[4] != 0:
            wr(g, a[4], sslcore.concat([[4, 0, 0, 0]]))
    return 0


# ================= System V shared memory (the X server and its clients share their framebuffers this way) =================
# segment: [kernel segment id, size, key, removed]; linuxd holds one kernel reference until IPC_RMID, every attachment holds another, so a removed segment lives on until the last detach
func sys_shmget(g, a):
    let key = i32(a[0])
    let size = a[1]
    let flag = a[2]
    if key != 0:
        for id in keys(shm_segs):
            let e = shm_segs[id]
            if e[2] == key and not e[3]:
                if (flag & 0x400) != 0 and (flag & 0x200) != 0:
                    return -17
                if size > e[1]:
                    return -EINVAL
                return id
        if (flag & 0x200) == 0:
            return -2
    if size <= 0:
        return -EINVAL
    let kid = lx.shm_new(align_up(size) // 4096)
    if kid < 0:
        return -ENOMEM
    let id = shm_next
    shm_next += 1
    shm_segs[id] = [kid, size, key, false, 0]
    return id

func sys_shmat(g, a):
    let e = shm_segs[a[0]]
    if e == nil:
        return -EINVAL
    let n = align_up(e[1])
    let addr = a[1]
    if addr == 0:
        addr = g.mmap_next
        g.mmap_next += n + 4096
    elif (addr & 4095) != 0:
        return -EINVAL
    let r = lx.shm_attach(g.pid, addr, e[0])
    if r < 0:
        return -ENOMEM
    vm_add(g, addr, addr + n, 7 if (a[2] & 0x1000) == 0 else 5, "SYSV" .. to_string(a[0]))
    if shm_attached[g.pid] == nil:
        shm_attached[g.pid] = {}
    shm_attached[g.pid][addr] = [a[0], n]
    e[4] += 1
    return addr

func sys_shmdt(g, a):
    let t = shm_attached[g.pid]
    if t == nil or t[a[0]] == nil:
        return -EINVAL
    let at = t[a[0]]
    lx.shm_detach(g.pid, a[0])
    vm_remove(g, a[0], a[0] + at[1])
    t[a[0]] = nil
    let e = shm_segs[at[0]]
    if e != nil:
        e[4] -= 1
        if e[3] and e[4] <= 0:
            shm_segs[at[0]] = nil
    return 0

func sys_shmctl(g, a):
    let e = shm_segs[a[0]]
    if e == nil:
        return -EINVAL
    let cmd = a[1] & 0xFF
    if cmd == 0:                      # IPC_RMID
        if not e[3]:
            e[3] = true
            lx.shm_drop(e[0])
        if e[4] <= 0:
            shm_segs[a[0]] = nil
        return 0
    if cmd == 2 or cmd == 13:         # IPC_STAT, SHM_STAT
        let b = []
        for i in range(112):
            b.append(0)
        put32(b, 4, 0)
        put32(b, 0, e[2])
        put32(b, 20, 0o666)
        put64(b, 48, e[1])
        put32(b, 80, g.pid)
        put64(b, 88, e[4])
        return wr(g, a[2], sslcore.concat([b])) if a[2] != 0 else -EFAULT
    return 0                          # IPC_SET, SHM_LOCK ... : accepted

func shm_fork(parent, child):
    let t = shm_attached[parent]
    if t == nil:
        return 0
    let c = {}
    for addr in keys(t):
        c[addr] = t[addr]
        let e = shm_segs[t[addr][0]]
        if e != nil:
            e[4] += 1
    shm_attached[child] = c
    return 0

func shm_exit(pid):
    let t = shm_attached[pid]
    if t == nil:
        return 0
    for addr in keys(t):
        let e = shm_segs[t[addr][0]]
        if e != nil:
            e[4] -= 1
            if e[3] and e[4] <= 0:
                shm_segs[t[addr][0]] = nil
    shm_attached[pid] = nil
    return 0


# ================= more of the system call table, as C-OS has it =================
let memfd_n = 0

# memfd_create: an anonymous file, kept on the volume under /tmp/.memfd and unlinked when the program ends with it
func sys_memfd_create(g, a):
    memfd_n += 1
    let path = "/tmp/.memfd-" .. to_string(g.pid) .. "-" .. to_string(memfd_n)
    try:
        fs.mkdir("/tmp")
    catch e:
        pass
    return do_open(g, path, 0o102 | 0o2, 0o600)

# inotify: the descriptor exists and can be polled, but nothing ever changes under it (Firefox only wants it not to fail)
let inotify_wd = 0
func sys_inotify_init(g, a):
    return g.alloc_fd({kind: "eventfd", count: 0, sem: false})
func sys_inotify_add_watch(g, a):
    inotify_wd += 1
    return inotify_wd

func sys_sched_prio(g, a):
    return 99 if a[0] == 1 or a[0] == 2 else 0
func sys_sched_prio_min(g, a):
    return 1 if a[0] == 1 or a[0] == 2 else 0

# mincore: every page the program has mapped counts as resident (as C-OS answers)
func sys_mincore(g, a):
    let n = (a[1] + 4095) // 4096
    if n <= 0:
        return 0
    let ones = []
    for i in range(n):
        ones.append(1)
    return wr(g, a[2], sslcore.concat([ones]))

# link, linkat: a hard link (the lock files of the X server are made this way)
func do_link(g, old, new):
    if old == nil or new == nil:
        return -EFAULT
    try:
        fs.link(abspath_nf(g, old), abspath_nf(g, new))
        links_changed()
        return 0
    catch e:
        return -errno_of(e.kind)

func sys_link(g, a):
    return do_link(g, cstr(g, a[0]), cstr(g, a[1]))

func sys_linkat(g, a):
    let old = cstr(g, a[1])
    let new = cstr(g, a[3])
    if old == nil or new == nil:
        return -EFAULT
    let o = at_path(g, a[0], old, false)
    let n = at_path(g, a[2], new, false)
    if o == nil or n == nil:
        return -EBADF
    return do_link(g, o, n)

# getresuid, getresgid: root all three
func sys_getres(g, a):
    let z = sslcore.concat([[0, 0, 0, 0]])
    for i in range(3):
        if a[i] != 0 and wr(g, a[i], z) != 0:
            return -EFAULT
    return 0

func sys_eopnotsupp(g, a):
    return -95
func sys_enodata(g, a):
    return -61
func sys_eperm(g, a):
    return -1
func sys_rseq(g, a):
    return -38

func setup():
    table[0] = sys_read
    table[1] = sys_write
    table[2] = sys_open
    table[3] = sys_close
    table[4] = sys_stat
    table[5] = sys_fstat
    table[6] = sys_lstat
    table[8] = sys_lseek
    table[9] = sys_mmap
    for nr in [116, 117, 119, 122, 123, 125, 126, 135, 140, 141, 142, 143, 144, 145, 149, 150, 151, 152, 251, 252, 272, 306, 308, 314, 325]:
        table[nr] = sys_zero      # setgroups, setres[ug]id, setfs[ug]id, capget/capset, personality, [gs]etpriority, sched_*, mlock*, ioprio_*, unshare, syncfs, setns, sched_setattr, mlock2
    table[146] = sys_sched_prio
    table[147] = sys_sched_prio_min
    table[148] = sys_zero
    for nr in [188, 189, 190]:
        table[nr] = sys_eopnotsupp    # setxattr: not supported
    for nr in [191, 192, 193, 197, 198, 199]:
        table[nr] = sys_enodata       # getxattr, removexattr: no attributes
    for nr in [194, 195, 196]:
        table[nr] = sys_zero          # listxattr: an empty list
    table[253] = sys_inotify_init
    table[294] = sys_inotify_init
    table[254] = sys_inotify_add_watch
    table[255] = sys_zero
    table[319] = sys_memfd_create
    table[334] = sys_rseq
    table[161] = sys_eperm
    table[27] = sys_mincore
    table[283] = sys_timerfd_create
    table[286] = sys_timerfd_settime
    table[287] = sys_timerfd_gettime
    table[118] = sys_getres
    table[120] = sys_getres
    table[86] = sys_link
    table[265] = sys_linkat
    table[29] = sys_shmget
    table[30] = sys_shmat
    table[31] = sys_shmctl
    table[67] = sys_shmdt
    table[10] = sys_mprotect
    table[11] = sys_munmap
    table[12] = sys_brk
    table[13] = sys_sigaction
    table[15] = sys_rt_sigreturn
    table[34] = sys_pause
    table[36] = sys_getitimer
    table[37] = sys_alarm
    table[38] = sys_setitimer
    table[127] = sys_sigpending
    table[128] = sys_sigtimedwait
    table[130] = sys_sigsuspend
    table[24] = sys_zero
    table[56] = sys_clone
    table[200] = sys_tkill
    table[204] = sys_sched_getaffinity
    table[234] = sys_tgkill
    table[273] = sys_zero
    table[14] = sys_sigprocmask
    table[16] = sys_ioctl
    table[17] = sys_pread
    table[18] = sys_pwrite
    table[20] = sys_writev
    table[21] = sys_access
    table[25] = sys_mremap
    table[28] = sys_zero
    table[22] = (g, a) => sys_pipe(g, [a[0], 0, 0])      # pipe(): no flags
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
    table[88] = sys_symlink
    table[266] = sys_symlinkat
    table[96] = sys_gettimeofday
    table[99] = sys_sysinfo
    table[102] = sys_getuid
    table[104] = sys_getuid
    table[107] = sys_getuid
    table[108] = sys_getuid
    table[111] = sys_getpid
    table[131] = sys_sigaltstack
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
    table[41] = sys_socket
    table[42] = sys_connect
    table[43] = sys_accept3
    table[44] = sys_sendto
    table[45] = sys_recvfrom
    table[46] = sys_sendmsg
    table[47] = sys_recvmsg
    table[48] = sys_shutdown
    table[49] = sys_bind
    table[50] = sys_listen
    table[51] = sys_getsockname
    table[52] = sys_getpeername
    table[53] = sys_socketpair
    table[54] = sys_setsockopt
    table[55] = sys_getsockopt
    table[288] = sys_accept
    table[7] = sys_poll
    table[19] = sys_readv
    table[23] = sys_select
    table[26] = sys_msync
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
    last_nr[cur_tid] = nr
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
    let t_end = psys.ms()
    if verbose == "prof":
        let pr = prof[nr]
        if pr == nil:
            pr = [0, 0]
            prof[nr] = pr
        pr[0] += 1
        pr[1] += t_end - t_start
        prof_busy += t_end - t_start
    if verbose and psys.ms() - t_start > 150:
        log("slow: tid " .. to_string(cur_tid) .. " syscall " .. to_string(nr) .. " (" .. to_string(a[0]) .. "," .. to_string(a[1]) .. "," .. to_string(a[2]) .. ") took " .. to_string(psys.ms() - t_start) .. " ms")
    if verbose == "trace" and cur_tid >= 7:
        log("tid " .. to_string(cur_tid) .. " syscall " .. to_string(nr) .. " (" .. to_string(a[0]) .. "," .. to_string(a[1]) .. "," .. to_string(a[2]) .. ") = " .. to_string(r))
    if r != nil:
        reply(cur_tid, r)

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
    elif q[0] == "snap":                       # write a shared file mapping back into its file (to look at what a program drew)
        ipc.send(src, "ok\t" .. to_string(shared_writeback(q[1])))
    elif q[0] == "quit":
        if verbose == "prof":
            log("prof: lx.write " .. to_string(prof_wr) .. " ms for " .. to_string(prof_wrn) .. " bytes; do_read " .. to_string(prof_rd) .. " ms")
            log("prof: " .. to_string(prof_busy) .. " ms inside system calls of " .. to_string(psys.ms()) .. " ms")
            for nr in keys(prof):
                if prof[nr][1] > 20:
                    log("prof: syscall " .. to_string(nr) .. " x" .. to_string(prof[nr][0]) .. " " .. to_string(prof[nr][1]) .. " ms")
        ipc.send(src, "ok")
        return false
    return true

try:
    fs = fsclient.connect(3000)
catch e:
    log("no file system server: " .. to_string(e))
setup()
if ipc.lookup("net") != nil:
    net_up()
ipc.register("linux")
log("serving as \"linux\", pid " .. to_string(psys.pid()))
let running = true
while running:
    try:
        io.flush()
        let tmo = next_wake()
        let wd = waiter_deadline()
        let ad = alarm_deadline()
        if ad != 0 and (wd == 0 or ad < wd):
            wd = ad
        let td = timerfd_deadline()
        if td != 0 and (wd == 0 or td < wd):
            wd = td
        if wd != 0 and (tmo == 0 or wd < tmo):
            tmo = wd
        if verbose == "beat":
            if next_beat == 0:
                next_beat = psys.ms() + 20000
            let until_beat = imax(1, next_beat - psys.ms())
            if tmo == 0 or until_beat < tmo:
                tmo = until_beat              # wake up for the heartbeat even when nothing happens (the timeout is relative, in ms)
        let m = nil
        if fs != nil and len(fs.backlog) > 0:
            m = fs.backlog.remove_at(0)           # a message that came in while we waited for fsd
        else:
            m = ipc.recv_from(true, tmo)
        wake_sleepers()
        fire_alarms()
        if verbose == "beat" and psys.ms() >= next_beat:
            next_beat = psys.ms() + 20000
            let line = ""
            for t in keys(tmap):
                let gg = tmap[t]
                line = line .. " " .. to_string(t) .. ":" .. to_string(last_nr[t]) .. "/" .. to_string(gg.calls if gg != nil else 0) .. ("*" if blocked[t] != nil else "")
            log("beat at " .. to_string(psys.ms()) .. " ms (tid:last syscall/calls, * blocked):" .. line)
        if m == nil:
            net_pump()
            recheck()
            continue
        let src = m[0]
        let text = m[1]
        if verbose == "trace" and src >= 7:
            log("recv from " .. to_string(src) .. ": " .. text.slice(0, imin(30, len(text))))
        if net != nil and src == net.link.pid:
            net_message(text)
            recheck()
            continue
        let g = tmap[src]
        if g != nil:
            if text == "S":
                cur_tid = src
                serve_signal_check(g, src)
            elif text.starts_with("P\t"):
                cur_tid = src
                serve_lazy(g, src, text.split("\t"))
            elif text.starts_with("F\t"):
                cur_tid = src
                serve_fault(g, src, text.split("\t"))
            elif text.starts_with("X\t"):
                # the kernel ended it: the whole process goes
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
    catch e:
        log("main loop error: " .. to_string(e))
log("bye")
