# kproc: a user process = one address space + one saved CPU context + a table of memory regions.
# Pages are filled in on first touch (#PF), so stacks and mmap areas cost nothing until used.
import hw
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
    let inbox = []       # messages waiting (strings)
    let rbuf = 0         # where a blocked msg_recv wants its message
    let rcap = 0
    func init(self, pid, name):
        self.pid = pid
        self.name = name
        self.space = vmm.Space()
        self.ctx = hw.ctx_new()
        self.regions = []
        self.shm = []
        self.inbox = []
    func add_region(self, start, end, flags):
        let r = Region()
        r.start = start
        r.end = end
        r.flags = flags
        self.regions.append(r)
    func find_region(self, v):
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
    # make sure [addr, addr + n) is backed (a kernel write into a not yet touched page of a region)
    func ensure(self, addr, n):
        let a = addr & ~4095
        while a < addr + n:
            if not self.space.is_mapped(a):
                self.fault(a)
            a += 4096
    func mmap(self, len, flags):
        let n = (len + 4095) & ~4095
        let a = self.mmap_next
        self.mmap_next += n + 4096   # a guard page after every mapping
        self.add_region(a, a + n, flags)
        return a
    func munmap(self, a, len):
        let end = a + ((len + 4095) & ~4095)
        let keep = []
        for r in self.regions:
            if r.start >= a and r.end <= end:
                continue   # whole region goes
            if r.start < end and r.end > a:
                if r.start < a:
                    r.end = a
                else:
                    r.start = end
            keep.append(r)
        self.regions = keep
        self.space.unmap_free(a, end - a)
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
        shm.detach_all(self)
        self.space.destroy()
        hw.ctx_free(self.ctx)

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
