# sched: processes, the run queue and the timer-driven round-robin scheduler. Policy lives here, in Sprint; the
# C side only saves registers on a trap and returns the vector number to this loop.
import hw
import kmem
import kproc
import ksys
import lapic
import ioapic

const PF = 14
const SLICE_MS = 10

let procs = {}
let kick_needed = false
let order = []
let next_pid = 1
let image = nil
let preemptions = 0
export let switches = 0

func log(s):
    ksys.log(s)

# what a program may do beyond computing: the framebuffer and input (gui), and the I/O ports of a driver
const GUI = ["guid"]
const PORTS = {fsd: [0x1F0, 8, 0x3F6, 1, 0x170, 8, 0x376, 1], gpud: [0xCF8, 8], inputd: [0x60, 1, 0x64, 1], netd: [0xCF8, 8]}
const DRIVERS = ["gpud", "netd"]       # may map device registers and allocate DMA memory
let names = {}        # service name -> pid
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

# interrupts for drivers: the ISA irqs / interrupt inputs a program may take over
const IRQS = {inputd: [1, 12], netd: [10, 11, 16, 17, 18, 19, 20, 21, 22, 23]}
let irq_owner = {}    # global system interrupt -> pid

# queue a message for q (from the kernel: sender 0, or from process `from`); wakes q if it is waiting
func post(q, sender, m):
    q.inbox.append(m)
    q.inbox_from.append(sender)
    if q.state == "msgwait":
        deliver(q)
        kick_needed = true

# an interrupt from input `gsi` arrived: tell its driver (one message per interrupt; the input stays masked until the driver acks it)
func handle_irq(gsi):
    if gsi in irq_owner and irq_owner[gsi] in procs and procs[irq_owner[gsi]].state != "zombie":
        post(procs[irq_owner[gsi]], 0, "irq\t" .. to_string(gsi))
    else:
        log("interrupt " .. to_string(gsi) .. " has no driver")

func take_irqs():
    let bits = hw.irq_take()
    if bits != 0:
        for g in range(24):
            if (bits >> g) & 1 != 0:
                handle_irq(g)

export func init(img):
    image = img

export func spawn(mod, parent):
    let pid = next_pid
    next_pid += 1
    let p = kproc.spawn(pid, mod, image[0], image[1], ["userland", mod])
    if type(p) == "string":
        log("spawn " .. mod .. " failed: " .. p)
        return -2
    p.parent = parent
    p.gui = GUI.contains(mod)
    p.mmio = DRIVERS.contains(mod)
    p.dma = p.mmio
    if mod in PORTS:
        p.ports = PORTS[mod]
    procs[pid] = p
    order.append(pid)
    kick_needed = true
    return pid

func set_ret(p, v):
    hw.poke64(p.ctx + kproc.CTX_RAX, v)

func finish(p):
    # free the address space now; keep the exit status until the parent waits for it
    let code = p.exit_code
    p.destroy()
    p.state = "zombie"
    p.exit_code = code
    let par = procs[p.parent] if p.parent in procs else nil
    if par != nil and par.state == "wait" and par.waiting == p.pid:
        set_ret(par, code)
        par.state = "run"
        kick_needed = true
        reap(p.pid)
    elif par == nil:
        reap(p.pid)

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

# scheduler-level system calls; returns true when `p` can keep running (its result is already in rax)
func syscall(p):
    let nr = hw.peek64(p.ctx + kproc.CTX_RAX)
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
        if not (pid in procs) or procs[pid].parent != p.pid:
            set_ret(p, -10)
            return true
        let c = procs[pid]
        if c.state == "zombie":
            set_ret(p, c.exit_code)
            reap(pid)
            return true
        p.state = "wait"
        p.waiting = pid
        return false
    if nr == 1013:   # msg_send(pid, buf, len) -> len
        let q = procs[hw.peek64(p.ctx + kproc.CTX_RDI)] if hw.peek64(p.ctx + kproc.CTX_RDI) in procs else nil
        let n = hw.peek64(p.ctx + kproc.CTX_RDX)
        if q == nil or q.state == "zombie":
            set_ret(p, -3)
            return true
        if n < 0 or n > 4096 or len(q.inbox) >= 64:
            set_ret(p, -11 if n >= 0 and n <= 4096 else -22)
            return true
        let m = p.space.read(hw.peek64(p.ctx + kproc.CTX_RSI), n)
        if m == nil:
            set_ret(p, -14)
            return true
        post(q, p.pid, m)
        set_ret(p, n)
        return true
    if nr == 1015:   # ns_register(name, len) -> 0: the calling process serves `name`
        let nm = p.space.read(hw.peek64(p.ctx + kproc.CTX_RDI), hw.peek64(p.ctx + kproc.CTX_RSI))
        if nm == nil or len(nm) == 0 or len(nm) > 32:
            set_ret(p, -22)
        elif nm in names and names[nm] in procs and procs[names[nm]].state != "zombie":
            set_ret(p, -17)
        else:
            names[nm] = p.pid
            set_ret(p, 0)
        return true
    if nr == 1016:   # ns_lookup(name, len) -> pid of the server, or -2
        let nm = p.space.read(hw.peek64(p.ctx + kproc.CTX_RDI), hw.peek64(p.ctx + kproc.CTX_RSI))
        if nm == nil:
            set_ret(p, -14)
        elif nm in names and names[nm] in procs and procs[names[nm]].state != "zombie":
            set_ret(p, names[nm])
        else:
            set_ret(p, -2)
        return true
    if nr == 1030:   # irq_register(irq, pci): this driver takes interrupt `irq` (an ISA irq, or with pci != 0 a global system interrupt); returns the global interrupt number
        let irq = hw.peek64(p.ctx + kproc.CTX_RDI)
        let pci = hw.peek64(p.ctx + kproc.CTX_RSI) != 0
        let allowed = IRQS[p.name] if p.name in IRQS else []
        let gsi = irq if pci else ioapic.gsi_of(irq)
        if not allowed.contains(irq) or gsi < 0 or gsi >= 24:
            set_ret(p, -1)
        elif gsi in irq_owner and irq_owner[gsi] != p.pid and irq_owner[gsi] in procs and procs[irq_owner[gsi]].state != "zombie":
            set_ret(p, -16)
        else:
            irq_owner[gsi] = p.pid
            ioapic.route(gsi, lapic.id(), -1 if pci else irq)
            hw.irq_mask(gsi, 0)
            set_ret(p, gsi)
        return true
    if nr == 1031:   # irq_ack(gsi): the driver has served the device; let the interrupt through again
        let gsi = hw.peek64(p.ctx + kproc.CTX_RDI)
        if gsi in irq_owner and irq_owner[gsi] == p.pid:
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

func alive():
    let n = 0
    for pid in order:
        if procs[pid].state != "zombie":
            n += 1
    return n

let cur = {}      # cpu -> process running there
let rr = 0
let t_start = 0
let kicks = 0

# wake any sleeper whose time has come; true when some process is runnable now
func ready(now):
    let n = len(order)
    let any = false
    for k in range(n):
        let p = procs[order[k]]
        if p.state == "sleep" and p.wake <= now:
            p.state = "run"
        if p.state == "msgwait" and p.mwake != 0 and p.mwake <= now:
            p.mwake = 0
            p.state = "run"
            set_ret(p, -11)
        if p.state == "run":
            any = true
    return any

# called by a CPU that has nothing to do: the context to run next (0 = idle until the next interrupt)
export func pick(cpu):
    if t_start == 0:
        t_start = hw.ticks_us()
    let now = hw.ticks_us()
    take_irqs()
    ready(now)
    let n = len(order)
    for k in range(n):
        let i = (rr + k) % n
        let p = procs[order[i]]
        if p.state == "run":
            rr = (i + 1) % n
            p.state = "on"
            p.cpu = cpu
            io_apply(cpu, p)
            cur[cpu] = p
            switches += 1
            return p.ctx
    if alive() == 0:
        done()
    return 0

func done():
    log("scheduler: " .. to_string(switches) .. " switches, " .. to_string(preemptions) .. " timer preemptions, " .. to_string((hw.ticks_us() - t_start) // 1000) .. " ms")
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
        elif p.state == "run" or p.state == "zombie":
            pass
    elif v == lapic.TIMER_VECTOR:
        lapic.eoi()
        p.slices += 1
        preemptions += 1
    elif v == PF and p.fault(hw.peek64(p.ctx + kproc.CTX_CR2)):
        pass
    elif v >= ioapic.VECTOR_BASE and v < ioapic.VECTOR_BASE + 24:
        hw.irq_mask(v - ioapic.VECTOR_BASE, 1)
        lapic.eoi()
        handle_irq(v - ioapic.VECTOR_BASE)
    elif v >= 32 and v < 256:
        if v != 255:
            lapic.eoi()
    else:
        log("pid " .. to_string(p.pid) .. " (" .. p.name .. "): trap " .. to_string(v) .. " err=" .. to_string(hw.peek64(p.ctx + kproc.CTX_ERR)) .. " rip=" .. to_string(hw.peek64(p.ctx + kproc.CTX_RIP)) .. " cr2=" .. to_string(hw.peek64(p.ctx + kproc.CTX_CR2)))
        p.exit_code = 139
        finish(p)
    if kick_needed:
        kick_needed = false
        hw.kick()
