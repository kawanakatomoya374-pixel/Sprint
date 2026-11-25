# kproc: a user process = one address space + one saved CPU context + a table of memory regions.
# Pages are filled in on first touch (#PF), so stacks and mmap areas cost nothing until used.
import hw
import k
import kmem
import vmm
import kelf
import shm

export const CTX_RAX = 0
export const CTX_RDX = 24
export const CTX_RSI = 32
export const CTX_RDI = 40
export const CTX_R10 = 72
export const CTX_R8 = 56
export const CTX_R9 = 64
export const CTX_RIP = 120
export const CTX_RSP = 128
export const CTX_RFLAGS = 136
export const CTX_CS = 144
export const CTX_SS = 152
export const CTX_VEC = 160
export const CTX_ERR = 168
export const CTX_CR2 = 176
export const CTX_FSB = 184
export const CTX_CR3 = 192
export const CTX_FX = 256

export const STACK_TOP = vmm.USER_BASE + 0x40000000
export const STACK_MAX = 8 << 20
const MMAP_BASE = vmm.USER_BASE + 0x10000000

export class Region:
    let start = 0
    let end = 0
    let flags = 0
    let lazy = false          # file-backed: a first touch asks the server (linuxd) to fill the page

export class Process:
    let pid = 0
    let name = ""
    let space = nil
    let ctx = 0
    let regions = []
    let brk = 0
    let brk_base = 0
    let mmap_next = MMAP_BASE
    let exit_code = nil
    let faults = 0
    let state = "run"   # run | sleep | wait | zombie
    let wake = 0         # sleep deadline (microseconds)
    let waiting = 0      # pid being waited for
    let parent = 0
    let slices = 0       # times this process was preempted by the timer
    let cpu = -1
    let gui = false      # may map the framebuffer and read input
    let syscalls = 0
    let shm = []         # [segment id, address] of every shared segment mapped
    let shm_free = []    # address ranges [va, bytes] of segments that were detached (reused, so the mmap area never creeps up to the stack)
    let inbox = []       # messages waiting (strings)
    let inbox_from = []  # the sender's pid of each
    let rfrom = 0        # where a blocked msg_recv wants the sender's pid (0 = nowhere)
    let children = {}    # pids this process has started and not yet waited for (they may live on another CPU)
    let exited = {}      # child pid -> exit status, for children that ended before the parent waited
    let mmio = false     # may map device registers (a driver)
    let dma = false      # may allocate physically contiguous DMA memory
    let ports = []       # I/O port ranges [first, count, ...] this process may use (a driver)
    let rbuf = 0         # where a blocked msg_recv wants its message
    let rcap = 0
    let mm = nil         # a thread of a Linux program: the process whose memory (space, regions) it shares
    let live = 1         # (the owner of the memory) threads that still use it
    let sigpend = false  # a Linux program with a signal waiting: its next timer tick is reported to the server
    let lx = false       # may run Linux programs (the personality server linuxd)
    let handler = 0      # a Linux program: the pid of the server that answers its system calls (0 = an ordinary process)
    let mwake = 0        # when a blocked msg_recv with a timeout gives up (microseconds; 0 = never)
    func init(self, pid, name):
        self.pid = pid
        self.name = name
        self.space = vmm.Space()
        self.ctx = hw.ctx_new()
        self.regions = []
        self.shm = []
        self.inbox = []
        self.inbox_from = []
        self.children = {}
        self.exited = {}
        self.ports = []
    func owner(self):
        return self if self.mm == nil else self.mm
    func add_region(self, start, end, flags):
        if self.mm != nil:
            return self.mm.add_region(start, end, flags)
        let r = Region()
        r.start = start
        r.end = end
        r.flags = flags
        self.regions.append(r)
    func find_region(self, v):
        if self.mm != nil:
            return self.mm.find_region(v)
        for r in self.regions:
            if v >= r.start and v < r.end:
                return r
        return nil
    # handle a user page fault: back the page when it lies in a region. false = a real fault
    func fault(self, addr):
        let r = self.find_region(addr)
        if r == nil:
            return false
        self.faults += 1
        self.space.map_range(addr & ~4095, 4096, r.flags)
        return true
    # a not yet touched page of a lazy region: the server must fill it
    func lazy_miss(self, addr):
        let r = self.find_region(addr)
        return r != nil and r.lazy and not self.space.is_mapped(addr & ~4095)
    # a write to a page that fork shares: take a private copy (or the page itself when this is its last mapping). false = not a copy-on-write page
    func cow_fault(self, addr):
        let a = addr & ~4095
        let e = self.space.entry(a, false)
        if e == 0:
            return false
        let x = hw.peek64(e)
        if x & vmm.P == 0 or x & vmm.COW == 0:
            return false
        let old = x & 0x000FFFFFFFFFF000
        if kmem.refs(old) > 1:
            let q = kmem.alloc()
            hw.memcpy(q, old, 4096)
            hw.poke64(e, q | ((x & 0xFFF & ~vmm.COW) | vmm.W | vmm.P))
            kmem.release(old)
        else:
            hw.poke64(e, (x & ~vmm.COW) | vmm.W)
        hw.invlpg(a)
        return true
    # make sure [addr, addr + n) is backed (a kernel write into a not yet touched page of a region)
    func ensure(self, addr, n):
        let a = addr & ~4095
        while a < addr + n:
            if not self.space.is_mapped(a):
                self.fault(a)
            else:
                self.cow_fault(a)                  # the kernel is about to write there: not into a page another process still shares
            a += 4096
    # the same for a page the kernel only reads
    func ensure_read(self, addr, n):
        let a = addr & ~4095
        while a < addr + n:
            if not self.space.is_mapped(a):
                self.fault(a)
            a += 4096
    func mmap(self, len, flags):
        let n = (len + 4095) & ~4095
        let a = self.mmap_next
        if a + n + 4096 >= STACK_TOP - STACK_MAX - (1 << 20):
            a = self.find_gap(n + 4096)      # the bump pointer reached the stack: first fit among the holes
            if a == 0:
                return 0
        else:
            self.mmap_next += n + 4096   # a guard page after every mapping
        self.add_region(a, a + n, flags)
        return a
    # the lowest address >= MMAP_BASE where `need` bytes are free (0: none)
    func find_gap(self, need):
        let rs = self.owner().regions.slice(0, len(self.owner().regions))
        rs.sort((x, y) => x.start < y.start)
        let at = MMAP_BASE
        let top = STACK_TOP - STACK_MAX - (1 << 20)
        for r in rs:
            if r.end <= at:
                continue
            if r.start >= top:
                break
            if r.start - at >= need:
                return at
            at = r.end + 4096
        return at if top - at >= need else 0
    func munmap(self, a, len):
        let end = a + ((len + 4095) & ~4095)
        let keep = []
        for r in self.regions:
            if r.start >= a and r.end <= end:
                continue   # whole region goes
            if r.start < a and r.end > end:
                # a hole in the middle: the region is split in two
                let tail = Region()
                tail.start = end
                tail.end = r.end
                tail.flags = r.flags
                tail.lazy = r.lazy
                r.end = a
                keep.append(r)
                keep.append(tail)
                continue
            if r.start < end and r.end > a:
                if r.start < a:
                    r.end = a
                else:
                    r.start = end
            keep.append(r)
        self.regions = keep
        self.space.unmap_free(a, end - a)
        if end + 4096 == self.mmap_next and a >= MMAP_BASE:
            self.mmap_next = a
    # execve: a fresh, empty address space and registers (the old frames are freed)
    func reset_space(self):
        self.space.destroy()
        self.space = vmm.Space()
        self.regions = []
        self.brk = 0
        self.brk_base = 0
        self.mmap_next = MMAP_BASE
        setup_user(self, 0, 0)
        hw.poke64(self.ctx + CTX_FSB, 0)
    # change the protection of [a, a + len): regions are split at the edges and mapped pages get their new flags
    func mprotect(self, a, len, flags):
        let end = a + ((len + 4095) & ~4095)
        let out = []
        for r in self.regions:
            if r.end <= a or r.start >= end:
                out.append(r)
                continue
            if r.start < a:
                let left = Region()
                left.start = r.start
                left.end = a
                left.flags = r.flags
                left.lazy = r.lazy
                out.append(left)
            if r.end > end:
                let right = Region()
                right.start = end
                right.end = r.end
                right.flags = r.flags
                right.lazy = r.lazy
                out.append(right)
            let mid = Region()
            mid.start = imax(r.start, a)
            mid.end = imin(r.end, end)
            mid.flags = flags
            mid.lazy = r.lazy
            out.append(mid)
        self.regions = out
        let v = a & ~4095
        while v < end:
            let sk = self.space.skip_for(v)
            if sk > 0:
                v += sk
                continue
            let e = self.space.entry(v, false)
            if e != 0:
                let x = hw.peek64(e)
                if x & vmm.P != 0:
                    hw.poke64(e, (x & ~(vmm.W | vmm.NX)) | (flags & vmm.W if x & vmm.COW == 0 else 0))
                    hw.invlpg(v)
            v += 4096
    # mremap(old, oldlen, newlen, may_move): grow by moving the pages (no copying); returns the address or -ENOMEM
    func mremap(self, old, oldlen, newlen, may_move):
        let o = (oldlen + 4095) & ~4095
        let n = (newlen + 4095) & ~4095
        if n <= o:
            if n < o:
                self.munmap(old + n, o - n)
            return old
        if not may_move:
            return -12
        let r = self.find_region(old)
        if r == nil:
            return -14
        let a = self.mmap_next
        self.mmap_next += n + 4096
        self.add_region(a, a + n, r.flags)
        let off = 0
        while off < o:
            self.space.move_page(old + off, a + off)
            off += 4096
        # forget the old region (its frames now belong to the new one)
        let keep = []
        for q in self.regions:
            if not (q.start >= old and q.end <= old + o):
                keep.append(q)
        self.regions = keep
        return a
    func destroy(self):
        if self.mm != nil:
            # a thread: the memory is shared; the last one out frees it
            hw.ctx_free(self.ctx)
            self.mm.live -= 1
            if self.mm.live == 0 and self.mm.state == "zombie":
                self.mm.space.destroy()
            return nil
        if self.live > 1:
            # the process ended but threads still run on its memory: keep it until they are gone
            self.live -= 1
            hw.ctx_free(self.ctx)
            return nil
        shm.detach_all(self)
        self.space.destroy()
        hw.ctx_free(self.ctx)

func imax(a, b):
    return a if a > b else b

func imin(a, b):
    return a if a < b else b

# a user context that starts at rip with stack pointer sp (ring 3, interrupts on, FPU / SSE state reset)
export func setup_user(p, rip, sp):
    hw.poke64(p.ctx + CTX_RIP, rip)
    hw.poke64(p.ctx + CTX_RSP, sp)
    hw.poke64(p.ctx + CTX_RFLAGS, 0x202)
    hw.poke64(p.ctx + CTX_CS, 0x23)
    hw.poke64(p.ctx + CTX_SS, 0x1B)
    hw.poke64(p.ctx + CTX_CR3, p.space.pml4)
    hw.poke16(p.ctx + CTX_FX, 0x37F)
    hw.poke32(p.ctx + CTX_FX + 24, 0x1F80)

# a thread: a new process that shares src's memory; registers are copied (the thread sees 0 in rax and starts on stack sp)
export func clone_thread(src, pid, sp):
    let owner = src.owner()
    let c = Process(pid, src.name)
    c.space.destroy()
    c.space = owner.space
    c.mm = owner
    owner.live += 1
    c.parent = src.pid
    c.handler = src.handler
    hw.memcpy(c.ctx, src.ctx, 768)
    hw.poke64(c.ctx + CTX_RAX, 0)
    if sp != 0:
        hw.poke64(c.ctx + CTX_RSP, sp)
    return c

# fork: a new process (pid) with a copy of src's regions, mapped pages and registers
export func fork(src, pid):
    let c = Process(pid, src.name)
    let o = src.owner()
    c.parent = src.pid
    c.handler = src.handler
    c.lx = false
    c.brk = o.brk
    c.brk_base = o.brk_base
    c.mmap_next = o.mmap_next
    for r in o.regions:
        c.add_region(r.start, r.end, r.flags)
        c.regions[len(c.regions) - 1].lazy = r.lazy
        let a = r.start
        while a < r.end:
            let sk = o.space.skip_for(a)              # (a region that was only reserved has no page tables: nothing to share)
            if sk > 0:
                a += sk
                continue
            let e = o.space.entry(a, false)
            let x = hw.peek64(e) if e != 0 else 0
            if x & vmm.P != 0:
                let phys = x & 0x000FFFFFFFFFF000
                let fl = x & 0xFFF
                if fl & vmm.DEVICE == 0:
                    if fl & vmm.W != 0:               # both sides now map the page read-only; the first one to write gets its own copy
                        fl = (fl & ~vmm.W) | vmm.COW
                        hw.poke64(e, (x & ~vmm.W) | vmm.COW)
                        hw.invlpg(a)
                    kmem.ref(phys)
                c.space.map(a, phys, fl & ~vmm.P)
            a += 4096
    for e in o.shm:                       # attached shared segments are inherited
        shm.attach_at(c, e[1], e[0], e[3] if len(e) > 3 else 0, e[2] if len(e) > 2 else -1)
    hw.memcpy(c.ctx, src.ctx, 768)
    hw.poke64(c.ctx + CTX_CR3, c.space.pml4)
    return c

# push a C string below sp; returns the new sp
func push_str(proc, sp, s):
    sp -= len(s) + 1
    proc.space.write(sp, s .. "\0")
    return sp

# spawn a process from an ELF image in physical memory; argv is an array of strings
export func spawn(pid, name, src, n, argv):
    let p = Process(pid, name)
    let im = kelf.load(p.space, src, n, vmm.USER_BASE + 0x400000)
    if not im.ok:
        p.destroy()
        return im.why
    p.brk_base = im.top + 0x100000
    p.brk = p.brk_base
    p.add_region(STACK_TOP - STACK_MAX, STACK_TOP, vmm.W | vmm.U)
    p.space.map_range(STACK_TOP - 4096, 4096, vmm.W | vmm.U)
    let sp = STACK_TOP - 64
    let ptrs = []
    for a in argv:
        sp = push_str(p, sp, a)
        ptrs.append(sp)
    sp -= 32
    let rnd = sp
    p.space.write(rnd, "sprint-os-rand!!")
    sp &= ~15
    let aux = [3, im.phdr, 4, im.phent, 5, im.phnum, 6, 4096, 7, 0, 9, im.entry, 23, 0, 25, rnd, 0, 0]
    let words = [len(argv)]
    for q in ptrs:
        words.append(q)
    words.append(0)   # argv terminator
    words.append(0)   # envp terminator
    for w in aux:
        words.append(w)
    sp -= len(words) * 8
    sp &= ~15
    for i in range(len(words)):
        p.space.write64(sp + i * 8, words[i])
    hw.poke64(p.ctx + CTX_RIP, im.entry)
    hw.poke64(p.ctx + CTX_RSP, sp)
    hw.poke64(p.ctx + CTX_RFLAGS, 0x202)
    hw.poke64(p.ctx + CTX_CS, 0x23)
    hw.poke64(p.ctx + CTX_SS, 0x1B)
    hw.poke64(p.ctx + CTX_CR3, p.space.pml4)
    hw.poke16(p.ctx + CTX_FX, 0x37F)
    hw.poke32(p.ctx + CTX_FX + 24, 0x1F80)
    return p
