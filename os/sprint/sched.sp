# sched: processes, the run queue and the timer-driven round-robin scheduler. Policy lives here, in Sprint; the
# C side only saves registers on a trap and returns the vector number to this loop.
import hw
import kmem
import kproc
import vmm
import ksys
import lapic
import ioapic
import shm

const PF = 14
const SLICE_MS = 10

# Each CPU runs its own copy of this module in its own VM: its own process table and run queue. Processes do not move between CPUs; spawn() places a new one on
# the least loaded CPU. What crosses CPUs goes through the C side (module k): process ids, names, shared memory, and mailboxes (message, spawn request, exit
# notice) with an IPI to wake the receiver.
import k
const KIND_MSG = 1      # a = destination pid, b = sender pid, text = the message
const KIND_SPAWN = 2    # a = new pid, b = parent pid, text = the program
const KIND_EXIT = 3     # a = parent pid, b = child pid, c = exit status
const MAX_CPUS = 8

let me = -1             # this CPU
let procs = {}
let order = []
let image = nil
let preemptions = 0
export let switches = 0
let started = false

func log(s):
    ksys.log(s)

# what a program may do beyond computing: the framebuffer and input (gui), and the I/O ports of a driver
const GUI = ["guid"]
const PORTS = {fsd: [0x1F0, 8, 0x3F6, 1, 0x170, 8, 0x376, 1], gpud: [0xCF8, 8], inputd: [0x60, 1, 0x64, 1], netd: [0xCF8, 8]}
const LX = ["linuxd"]                 # may create and drive Linux programs
const DRIVERS = ["gpud", "netd"]       # may map device registers and allocate DMA memory
let io_open = {}      # cpu -> the port ranges currently open in its I/O permission bitmap
let io_pid = {}       # cpu -> pid they belong to

# make the I/O permission bitmap of `cpu` match what `p` may use
func io_apply(cpu, p):
    let want = p.pid if len(p.ports) > 0 else 0
    let have = io_pid[cpu] if cpu in io_pid else 0
    if want == have:
        return
    if have != 0:
        let r = io_open[cpu]
        for i in range(len(r) // 2):
            hw.iopb_set(cpu, r[2 * i], r[2 * i + 1], 0)
    if want != 0:
        for i in range(len(p.ports) // 2):
            hw.iopb_set(cpu, p.ports[2 * i], p.ports[2 * i + 1], 1)
        io_open[cpu] = p.ports
    io_pid[cpu] = want

# interrupts for drivers: the ISA irqs / interrupt inputs a program may take over (the owners are kept by the C side)
const IRQS = {inputd: [1, 12], netd: [10, 11, 16, 17, 18, 19, 20, 21, 22, 23]}

func set_ret(p, v):
    hw.poke64(p.ctx + kproc.CTX_RAX, v)

# queue a message for local process q (from the kernel: sender 0, or from a process); wakes q if it is waiting
func post(q, sender, m):
    if len(q.inbox) >= 64:
        return nil
    q.inbox.append(m)
    q.inbox_from.append(sender)
    if q.state == "msgwait":
        deliver(q)

# a message for any process, wherever it lives; false when it could not be queued
func send_to(pid, sender, m):
    let c = k.pid_cpu(pid)
    if c < 0:
        return false
    if c == me:
        if not (pid in procs):
            return false
        post(procs[pid], sender, m)
        return true
    return k.mbox_send(c, KIND_MSG, pid, sender, 0, m)

# an interrupt from input `gsi` arrived: tell its driver (one message per interrupt; the input stays masked until the driver acks it)
func handle_irq(gsi):
    let owner = k.irq_owner(gsi)
    if owner != 0:
        send_to(owner, 0, "irq\t" .. to_string(gsi))
    else:
        log("interrupt " .. to_string(gsi) .. " has no driver")

func take_irqs():
    let bits = hw.irq_take()
    if bits != 0:
        for g in range(24):
            if (bits >> g) & 1 != 0:
                handle_irq(g)

# this CPU's scheduler comes up
export func init(img, cpu):
    image = img
    me = cpu
    k.load_set(cpu, 0)

# the CPU with the fewest processes (among those whose scheduler is running)
func place():
    let best = me
    let bl = k.load_get(me)
    for c in range(MAX_CPUS):
        if c != me and k.ready(c) and k.load_get(c) < bl:
            best = c
            bl = k.load_get(c)
    return best

# create process `pid` here
func spawn_here(pid, mod, parent):
    let p = kproc.spawn(pid, mod, image[0], image[1], ["userland", mod])
    if type(p) == "string":
        log("spawn " .. mod .. " failed: " .. p)
        exit_notice(parent, pid, -2)
        k.pid_gone(pid)
        k.load_add(me, -1)
        return -2
    p.parent = parent
    p.cpu = me
    p.gui = GUI.contains(mod)
    p.mmio = DRIVERS.contains(mod)
    p.lx = LX.contains(mod)
    p.dma = p.mmio
    if mod in PORTS:
        p.ports = PORTS[mod]
    procs[pid] = p
    order.append(pid)
    return pid

# start `mod` as a child of `parent` on the least loaded CPU; returns the new pid
export func spawn(mod, parent):
    let c = place()
    let pid = k.pid_new(c)
    k.load_add(c, 1)
    if parent != 0 and parent in procs:
        procs[parent].children[pid] = true
    if c == me:
        spawn_here(pid, mod, parent)
    elif not k.mbox_send(c, KIND_SPAWN, pid, parent, 0, mod):
        k.pid_gone(pid)
        k.load_add(c, -1)
        return -11
    return pid

# a child ended: hand its status to the parent (on any CPU)
func exit_notice(parent, child, code):
    if parent == 0:
        return nil
    let c = k.pid_cpu(parent)
    if c < 0:
        return nil
    if c == me:
        child_exited(parent, child, code)
    else:
        k.mbox_send(c, KIND_EXIT, parent, child, code, "")

func child_exited(parent, child, code):
    if not (parent in procs):
        return nil
    let par = procs[parent]
    if par.state == "wait" and par.waiting == child:
        set_ret(par, code)
        par.state = "run"
        par.waiting = 0
        par.children[child] = nil
    else:
        par.exited[child] = code

func finish(p):
    # free the address space now and tell the parent how it ended; the process is gone
    let code = p.exit_code
    let handler = p.handler
    p.state = "zombie"
    p.destroy()
    reap(p.pid)
    if handler != 0:
        send_to(handler, p.pid, "X\t" .. to_string(code))      # a Linux program ended (also when it crashed): its server hears about it
    else:
        exit_notice(p.parent, p.pid, code)
    k.pid_gone(p.pid)
    k.load_add(me, -1)

func reap(pid):
    procs[pid] = nil
    let i = 0
    while i < len(order):
        if order[i] == pid:
            order.remove_at(i)
            return
        i += 1

# hand the oldest waiting message to p (its buffer is p.rbuf / p.rcap); the result goes into rax
func deliver(p):
    p.mwake = 0
    let m = p.inbox[0]
    let sender = p.inbox_from[0]
    p.inbox.remove_at(0)
    p.inbox_from.remove_at(0)
    if p.rfrom != 0:
        p.space.write64(p.rfrom, sender)
    let n = len(m)
    if n > p.rcap:
        n = p.rcap
        m = m.slice(0, n)
    p.ensure(p.rbuf, n)
    set_ret(p, n if p.space.write(p.rbuf, m) else -14)
    if p.state == "msgwait":
        p.state = "run"

# what other CPUs sent this one
func drain_mailbox():
    while true:
        let m = k.mbox_recv()
        if m == nil:
            return nil
        let kind = m[0]
        if kind == KIND_MSG:
            if m[1] in procs:
                post(procs[m[1]], m[2], m[4])
        elif kind == KIND_SPAWN:
            spawn_here(m[1], m[4], m[2])
        elif kind == KIND_EXIT:
            child_exited(m[1], m[2], m[3])

# scheduler-level system calls; returns true when `p` can keep running (its result is already in rax)
# the Linux programs of this CPU that `p` (a personality server) drives
func lx_target(p, pid):
    if not p.lx or not (pid in procs):
        return nil
    let q = procs[pid]
    return q if q.handler == p.pid else nil

# copy n bytes between two address spaces (the kernel sees all memory, so this is a page-wise physical copy); false when a page is not mapped
func copy_between(src_p, src_va, dst_p, dst_va, n):
    let done = 0
    while done < n:
        src_p.ensure(src_va + done, 1)
        dst_p.ensure(dst_va + done, 1)
        let a = src_p.space.translate(src_va + done)
        let b = dst_p.space.translate(dst_va + done)
        if a == nil or b == nil:
            return false
        let chunk = 4096 - (a & 4095)
        let c2 = 4096 - (b & 4095)
        if c2 < chunk:
            chunk = c2
        if chunk > n - done:
            chunk = n - done
        hw.memcpy(b, a, chunk)
        done += chunk
    return true

func lx_syscall(p, nr):
    let a0 = hw.peek64(p.ctx + kproc.CTX_RDI)
    let a1 = hw.peek64(p.ctx + kproc.CTX_RSI)
    let a2 = hw.peek64(p.ctx + kproc.CTX_RDX)
    let a3 = hw.peek64(p.ctx + kproc.CTX_R10)
    if nr == 1040:   # lx_create() -> pid: a Linux program with an empty address space, answered by the caller; not running yet
        if not p.lx:
            set_ret(p, -1)
            return true
        let pid = k.pid_new(me)
        k.load_add(me, 1)
        let q = kproc.Process(pid, "linux")
        q.parent = p.pid
        q.handler = p.pid
        q.cpu = me
        q.state = "stopped"
        kproc.setup_user(q, 0, 0)
        procs[pid] = q
        p.children[pid] = true
        set_ret(p, pid)
        return true
    if nr == 1060:   # lx_shm_new(pages): a segment the caller (linuxd) holds one reference to
        let id = k.shm_create(a0)
        if id > 0:
            k.shm_ref(id, 1)
        set_ret(p, id)
        return true
    if nr == 1061:   # lx_shm_drop(id): give that reference back (the segment goes when the last attachment does)
        k.shm_ref(a0, -1)
        set_ret(p, 0)
        return true
    let q = lx_target(p, a0)
    if q == nil:
        set_ret(p, -3)
        return true
    let m = q.owner()          # (the memory of a thread is its process's)
    if nr == 1041:   # lx_map(pid, addr, len, prot): a zero-filled region (pages appear when touched); prot bit 2 = writable
        let flags = vmm.U | (vmm.W if (a3 & 2) != 0 else 0)
        if (a1 & 4095) != 0 or a2 <= 0 or a1 < vmm.USER_BASE:
            set_ret(p, -22)
            return true
        m.munmap(a1, a2)
        m.add_region(a1, a1 + ((a2 + 4095) & ~4095), flags)
        if (a3 & 4) != 0:
            m.regions[len(m.regions) - 1].lazy = true
        set_ret(p, 0)
        return true
    if nr == 1042:   # lx_unmap(pid, addr, len)
        m.munmap(a1, a2)
        set_ret(p, 0)
        return true
    if nr == 1043:   # lx_protect(pid, addr, len, prot)
        m.mprotect(a1, a2, vmm.U | (vmm.W if (a3 & 2) != 0 else 0))
        set_ret(p, 0)
        return true
    if nr == 1044:   # lx_write(pid, addr, buf, n): copy n bytes from our buf into the program
        let n = hw.peek64(p.ctx + kproc.CTX_R10)
        set_ret(p, 0 if copy_between(p, a2, m, a1, n) else -14)
        return true
    if nr == 1045:   # lx_read(pid, addr, buf, n): copy n bytes from the program into our buf
        let n = hw.peek64(p.ctx + kproc.CTX_R10)
        set_ret(p, 0 if copy_between(m, a1, p, a2, n) else -14)
        return true
    if nr == 1046:   # lx_start(pid, rip, rsp): let it run
        kproc.setup_user(q, a1, a2)
        q.state = "run"
        if not order.contains(q.pid):
            order.append(q.pid)
        set_ret(p, 0)
        return true
    if nr == 1050:   # lx_fork(pid) -> child pid: a copy of the program's memory and registers (the child sees 0 in rax); it runs at once
        let c = kproc.fork(q, k.pid_new(me))
        k.load_add(me, 1)
        c.cpu = me
        procs[c.pid] = c
        p.children[c.pid] = true
        c.state = "stopped"          # lx_resume lets it run, once the server has recorded it
        set_ret(c, 0)
        set_ret(p, c.pid)
        return true
    if nr == 1052:   # lx_clone(pid, sp) -> tid: a thread on the same memory, stopped until lx_resume
        let c = kproc.clone_thread(q, k.pid_new(me), a1)
        k.load_add(me, 1)
        c.cpu = me
        procs[c.pid] = c
        p.children[c.pid] = true
        c.state = "stopped"
        set_ret(p, c.pid)
        return true
    if nr == 1053:   # lx_resume(pid)
        q.state = "run"
        if not order.contains(q.pid):
            order.append(q.pid)
        set_ret(p, 0)
        return true
    if nr == 1055:   # lx_getctx(pid, buf): 83 words: rax rbx rcx rdx rsi rdi rbp r8..r15 rip rsp rflags fsbase, then the 512-byte FXSAVE image
        let regs = [0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128, 136, 184]
        for i in range(19):
            if not p.space.write64(a1 + 8 * i, hw.peek64(q.ctx + regs[i])):
                set_ret(p, -14)
                return true
        for i in range(64):
            if not p.space.write64(a1 + 8 * (19 + i), hw.peek64(q.ctx + kproc.CTX_FX + 8 * i)):
                set_ret(p, -14)
                return true
        set_ret(p, 0)
        return true
    if nr == 1056:   # lx_setctx(pid, buf): the same layout back (flags are sanitised; segments and the page table stay)
        let regs = [0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128, 136, 184]
        for i in range(19):
            let v = p.space.read64(a1 + 8 * i)
            if v == nil:
                set_ret(p, -14)
                return true
            if regs[i] == 136:
                v = (v & 0xDD5) | 0x202
            hw.poke64(q.ctx + regs[i], v)
        for i in range(64):
            let v = p.space.read64(a1 + 8 * (19 + i))
            if v == nil:
                set_ret(p, -14)
                return true
            hw.poke64(q.ctx + kproc.CTX_FX + 8 * i, v)
        hw.poke32(q.ctx + kproc.CTX_FX + 24, hw.peek32(q.ctx + kproc.CTX_FX + 24) & 0xFFBF)    # MXCSR: reserved bits off
        set_ret(p, 0)
        return true
    if nr == 1057:   # lx_sigpend(pid, on): report the program at its next timer tick (so a signal can be delivered to code that makes no system calls)
        q.sigpend = a1 != 0
        set_ret(p, 0)
        return true
    if nr == 1058:   # lx_shm_attach(pid, addr, id): map shared segment `id` into the program at addr (System V shmat, shared mappings)
        set_ret(p, shm.attach_at(m, a1, a2))
        return true
    if nr == 1059:   # lx_shm_detach(pid, addr)
        set_ret(p, shm.detach(m, a1))
        return true
    if nr == 1054:   # lx_setsp(pid, sp)
        hw.poke64(q.ctx + kproc.CTX_RSP, a1)
        set_ret(p, 0)
        return true
    if nr == 1051:   # lx_reset(pid): throw the program's memory away (execve); it stays stopped until lx_start
        q.reset_space()
        q.state = "lxwait"
        set_ret(p, 0)
        return true
    if nr == 1047:   # lx_reply(pid, value): answer the system call it is waiting on
        if q.state != "lxwait":
            log("lx_reply to pid " .. to_string(q.pid) .. " in state " .. q.state)
            set_ret(p, -11)
            return true
        set_ret(q, a1)
        q.state = "run"
        set_ret(p, 0)
        return true
    if nr == 1048:   # lx_kill(pid, status)
        q.exit_code = a1
        finish(q)
        set_ret(p, 0)
        return true
    if nr == 1049:   # lx_setfs(pid, base): the thread pointer
        hw.poke64(q.ctx + kproc.CTX_FSB, a1)
        set_ret(p, 0)
        return true
    set_ret(p, -38)
    return true

func hex64(x):
    let d = "0123456789abcdef"
    let out = ""
    for i in range(16):
        out = out .. d.slice(((x >> (60 - 4 * i)) & 15), ((x >> (60 - 4 * i)) & 15) + 1)
    return out

# words from `va`, equal neighbours folded ("0000000000000000 x100000"); unmapped memory shows as "--"
func dump_words(proc, va, n):
    let out = ""
    let prev = nil
    let run = 0
    for i in range(n):
        let w = proc.space.read64(va + 8 * i)
        let t = "--" if w == nil else hex64(w)
        if t == prev:
            run += 1
            continue
        if prev != nil:
            out = out .. " " .. prev .. (" x" .. to_string(run) if run > 1 else "")
        prev = t
        run = 1
    if prev != nil:
        out = out .. " " .. prev .. (" x" .. to_string(run) if run > 1 else "")
    return out

# what a fault looks like: registers, the code bytes at rip, the top of the stack
func trap_dump(p):
    let rip = hw.peek64(p.ctx + kproc.CTX_RIP)
    let rsp = hw.peek64(p.ctx + kproc.CTX_RSP)
    log("  code at rip " .. hex64(rip) .. ":" .. dump_words(p, rip & ~7, 6))
    log("  stack at rsp " .. hex64(rsp) .. ":" .. dump_words(p, rsp & ~7, 24))
    log("  regs rbx=" .. hex64(hw.peek64(p.ctx + 8)) .. " rbp=" .. hex64(hw.peek64(p.ctx + 48)) .. " rdi=" .. hex64(hw.peek64(p.ctx + 40)) .. " rsi=" .. hex64(hw.peek64(p.ctx + 32)))

func syscall(p):
    let nr = hw.peek64(p.ctx + kproc.CTX_RAX)
    if p.handler != 0:
        # a Linux program: the system call goes to its server as a message "nr<TAB>a0 ... a5", and the program waits for lx_reply
        let m = to_string(nr)
        for r in [kproc.CTX_RDI, kproc.CTX_RSI, kproc.CTX_RDX, kproc.CTX_R10, kproc.CTX_R8, kproc.CTX_R9]:
            m = m .. "\t" .. to_string(hw.peek64(p.ctx + r))
        if send_to(p.handler, p.pid, m):
            p.state = "lxwait"
            return false
        p.exit_code = 137
        return false
    if nr >= 1040 and nr < 1070:
        return lx_syscall(p, nr)
    if nr == 35:   # nanosleep(&ts, nil)
        let ts = p.space.read64(hw.peek64(p.ctx + kproc.CTX_RDI))
        let ns = p.space.read64(hw.peek64(p.ctx + kproc.CTX_RDI) + 8)
        set_ret(p, 0)
        if ts == nil or ns == nil:
            set_ret(p, -14)
            return true
        p.wake = hw.ticks_us() + ts * 1000000 + ns // 1000
        p.state = "sleep"
        return false
    if nr == 1000:   # spawn(name, len) -> pid
        let name = p.space.read(hw.peek64(p.ctx + kproc.CTX_RDI), hw.peek64(p.ctx + kproc.CTX_RSI))
        set_ret(p, -14 if name == nil else spawn(name, p.pid))
        return true
    if nr == 1001:   # wait(pid) -> exit status
        let pid = hw.peek64(p.ctx + kproc.CTX_RDI)
        if not (pid in p.children):
            set_ret(p, -10)
            return true
        if pid in p.exited:
            set_ret(p, p.exited[pid])
            p.exited[pid] = nil
            p.children[pid] = nil
            return true
        p.state = "wait"
        p.waiting = pid
        return false
    if nr == 1013:   # msg_send(pid, buf, len) -> len
        let dest = hw.peek64(p.ctx + kproc.CTX_RDI)
        let n = hw.peek64(p.ctx + kproc.CTX_RDX)
        if k.pid_cpu(dest) < 0:
            set_ret(p, -3)
            return true
        if n < 0 or n > 4096:
            set_ret(p, -22)
            return true
        let m = p.space.read(hw.peek64(p.ctx + kproc.CTX_RSI), n)
        if m == nil:
            set_ret(p, -14)
            return true
        if not send_to(dest, p.pid, m):
            set_ret(p, -11)
            return true
        set_ret(p, n)
        return true
    if nr == 1015:   # ns_register(name, len) -> 0: the calling process serves `name`
        let nm = p.space.read(hw.peek64(p.ctx + kproc.CTX_RDI), hw.peek64(p.ctx + kproc.CTX_RSI))
        if nm == nil:
            set_ret(p, -14)
        else:
            set_ret(p, k.name_set(nm, p.pid))
        return true
    if nr == 1016:   # ns_lookup(name, len) -> pid of the server, or -2
        let nm = p.space.read(hw.peek64(p.ctx + kproc.CTX_RDI), hw.peek64(p.ctx + kproc.CTX_RSI))
        set_ret(p, -14 if nm == nil else k.name_get(nm))
        return true
    if nr == 1030:   # irq_register(irq, pci): this driver takes interrupt `irq` (an ISA irq, or with pci != 0 a global system interrupt); returns the global interrupt number
        let irq = hw.peek64(p.ctx + kproc.CTX_RDI)
        let pci = hw.peek64(p.ctx + kproc.CTX_RSI) != 0
        let allowed = IRQS[p.name] if p.name in IRQS else []
        let gsi = irq if pci else ioapic.gsi_of(irq)
        if not allowed.contains(irq) or gsi < 0 or gsi >= 24:
            set_ret(p, -1)
        elif k.irq_owner_set(gsi, p.pid) != 0:
            set_ret(p, -16)
        else:
            ioapic.route(gsi, lapic.id(), -1 if pci else irq)
            hw.irq_mask(gsi, 0)
            set_ret(p, gsi)
        return true
    if nr == 1031:   # irq_ack(gsi): the driver has served the device; let the interrupt through again
        let gsi = hw.peek64(p.ctx + kproc.CTX_RDI)
        if k.irq_owner(gsi) == p.pid:
            hw.irq_mask(gsi, 0)
            set_ret(p, 0)
        else:
            set_ret(p, -1)
        return true
    if nr == 1014:   # msg_recv(buf, cap, nonblock) -> bytes (blocks when nothing is waiting)
        p.rbuf = hw.peek64(p.ctx + kproc.CTX_RDI)
        p.rcap = hw.peek64(p.ctx + kproc.CTX_RSI)
        p.rfrom = hw.peek64(p.ctx + kproc.CTX_R10)
        if len(p.inbox) == 0:
            if hw.peek64(p.ctx + kproc.CTX_RDX) != 0:
                set_ret(p, -11)
                return true
            let tmo = hw.peek64(p.ctx + kproc.CTX_R8)       # timeout in microseconds (0 = wait for ever)
            p.mwake = hw.ticks_us() + tmo if tmo > 0 else 0
            p.state = "msgwait"
            return false
        deliver(p)
        return true
    let r = ksys.dispatch(p)
    if p.exit_code != nil:
        return false
    set_ret(p, r)
    return true

let cur = {}      # cpu -> process running there
let rr = 0
let t_start = 0

# wake any sleeper whose time has come; true when some process is runnable now
func ready(now):
    let n = len(order)
    let any = false
    for i in range(n):
        let p = procs[order[i]]
        if p.state == "sleep" and p.wake <= now:
            p.state = "run"
        if p.state == "msgwait" and p.mwake != 0 and p.mwake <= now:
            p.mwake = 0
            p.state = "run"
            set_ret(p, -11)
        if p.state == "run":
            any = true
    return any

# the first process exists: from now on, when no process is left anywhere the machine is done
export func boot_done():
    started = true
    k.flag_set(1)

# called by a CPU that has nothing to do: the context to run next (0 = idle until the next interrupt)
export func pick(cpu):
    if t_start == 0:
        t_start = hw.ticks_us()
    let now = hw.ticks_us()
    drain_mailbox()
    take_irqs()
    ready(now)
    let n = len(order)
    for i in range(n):
        let j = (rr + i) % n
        let p = procs[order[j]]
        if p.state == "run":
            rr = (j + 1) % n
            p.state = "on"
            p.cpu = cpu
            io_apply(cpu, p)
            cur[cpu] = p
            switches += 1
            k.stat_set(cpu, 0, switches)
            return p.ctx
    if k.flag_get(1) != 0 and k.nproc() == 0:
        done()
    return 0

func done():
    if k.flag_set(2) != 0:
        return nil
    let per = []
    let total = 0
    let pre = 0
    for c in range(MAX_CPUS):
        let r = k.stat_get(c, 0)
        total += r
        pre += k.stat_get(c, 1)
        if r > 0:
            per.append("cpu" .. to_string(c) .. "=" .. to_string(r))
    log("scheduler: " .. to_string(total) .. " switches, " .. to_string(pre) .. " timer preemptions, " .. to_string((hw.ticks_us() - t_start) // 1000) .. " ms")
    log("runs per cpu: " .. per.join(" "))
    log("free pages after exit: " .. to_string(kmem.free_count()))
    hw.poweroff()

# called after the process on `cpu` trapped with vector v
export func trap(cpu, v):
    let p = cur[cpu]
    cur[cpu] = nil
    p.state = "run"
    if v == 256:
        if not syscall(p) and p.exit_code != nil:
            finish(p)
    elif v == lapic.TIMER_VECTOR:
        lapic.eoi()
        if p.handler != 0 and p.sigpend:
            p.sigpend = false
            if send_to(p.handler, p.pid, "S"):
                p.state = "lxwait"
        p.slices += 1
        preemptions += 1
        k.stat_set(cpu, 1, preemptions)
    elif v == PF and p.handler != 0 and p.lazy_miss(hw.peek64(p.ctx + kproc.CTX_CR2)):
        # a page of a file mapping: the server reads it from the file, then lets the instruction run again
        if send_to(p.handler, p.pid, "P\t" .. to_string(hw.peek64(p.ctx + kproc.CTX_CR2))):
            p.state = "lxwait"
        else:
            p.exit_code = 139
            finish(p)
    elif v == PF and p.fault(hw.peek64(p.ctx + kproc.CTX_CR2)):
        pass
    elif v >= ioapic.VECTOR_BASE and v < ioapic.VECTOR_BASE + 24:
        hw.irq_mask(v - ioapic.VECTOR_BASE, 1)
        lapic.eoi()
        handle_irq(v - ioapic.VECTOR_BASE)
    elif v >= 32 and v < 256:
        if v != 255:
            lapic.eoi()
    elif p.handler != 0 and (v == 0 or v == 6 or v == 13 or v == PF or v == 16 or v == 17 or v == 19):
        # an exception in a Linux program: the server turns it into a signal (a handler may run, or the program ends)
        if send_to(p.handler, p.pid, "F\t" .. to_string(v) .. "\t" .. to_string(hw.peek64(p.ctx + kproc.CTX_CR2)) .. "\t" .. to_string(hw.peek64(p.ctx + kproc.CTX_ERR))):
            p.state = "lxwait"
        else:
            p.exit_code = 139
            finish(p)
    else:
        log("pid " .. to_string(p.pid) .. " (" .. p.name .. "): trap ".. to_string(v) .. " err=" .. to_string(hw.peek64(p.ctx + kproc.CTX_ERR)) .. " rip=" .. to_string(hw.peek64(p.ctx + kproc.CTX_RIP)) .. " rsp=" .. to_string(hw.peek64(p.ctx + kproc.CTX_RSP)) .. " rax=" .. to_string(hw.peek64(p.ctx + kproc.CTX_RAX)) .. " cs=" .. to_string(hw.peek64(p.ctx + 144)) .. " cr2=" .. to_string(hw.peek64(p.ctx + kproc.CTX_CR2)))
        trap_dump(p)
        p.exit_code = 139
        finish(p)
