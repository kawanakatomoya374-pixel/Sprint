# ksys: the system-call table for user processes (Linux x86-64 numbering, so musl runs unmodified).
import hw
import kmem
import kproc
import shm
import vmm
import ps2
import rtc

const ENOENT = -2
const EBADF = -9
const ENOMEM = -12
const EFAULT = -14
const ENOTTY = -25
const ENOSYS = -38
const EPERM = -1
const FB_BASE = vmm.USER_BASE + 0x20000000

let input_dev = nil
let input_buf = []

export func log(s):
    hw.serial("[kernel] " .. s .. "\n")

func arg(p, n):
    if n == 0:
        return hw.peek64(p.ctx + kproc.CTX_RDI)
    if n == 1:
        return hw.peek64(p.ctx + kproc.CTX_RSI)
    if n == 2:
        return hw.peek64(p.ctx + kproc.CTX_RDX)
    if n == 3:
        return hw.peek64(p.ctx + kproc.CTX_R10)
    if n == 4:
        return hw.peek64(p.ctx + kproc.CTX_R8)
    return hw.peek64(p.ctx + kproc.CTX_R9)

func console(p, s):
    hw.serial(s)

func sys_writev(p, fd, iov, cnt):
    if fd != 1 and fd != 2:
        return EBADF
    let total = 0
    for i in range(cnt):
        let base = p.space.read64(iov + i * 16)
        let n = p.space.read64(iov + i * 16 + 8)
        if base == nil or n == nil:
            return EFAULT
        if n > 0:
            let s = p.space.read(base, n)
            if s == nil:
                return EFAULT
            console(p, s)
            total += n
    return total

# fb_map(out): map the framebuffer into the caller and store [va, width, height, pitch] at out
func sys_fb_map(p, out):
    if not p.gui:
        return EPERM
    let info = hw.fb_info()
    if info == nil:
        return -19
    let bytes = info[2] * info[1]
    let pages = (bytes + 4095) // 4096
    for i in range(pages):
        p.space.map(FB_BASE + i * 4096, info[4] + i * 4096, vmm.W | vmm.U | vmm.DEVICE)
    p.space.write64(out, FB_BASE)
    p.space.write64(out + 8, info[0])
    p.space.write64(out + 16, info[1])
    p.space.write64(out + 24, info[2])
    return 0

# input(buf, cap): events from the keyboard and mouse as text lines; returns the number of bytes stored
func sys_input(p, buf, cap):
    if not p.gui:
        return EPERM
    let info = hw.fb_info()
    if input_dev == nil:
        input_dev = ps2.Input(info[0], info[1])
    for ev in input_dev.poll():
        input_buf.append(ps2.encode(ev))
    if len(input_buf) == 0:
        return 0
    let out = ""
    let used = 0
    while len(input_buf) > 0 and used + len(input_buf[0]) + 1 <= cap:
        out = out .. input_buf[0] .. "\n"
        used += len(input_buf[0]) + 1
        input_buf.remove_at(0)
    if used == 0:
        return -22
    p.space.write(buf, out)
    return used

# returns the syscall result; sets p.exit_code when the process ends
export func dispatch(p):
    let nr = hw.peek64(p.ctx + kproc.CTX_RAX)
    p.syscalls += 1
    if nr == 1:
        if arg(p, 0) != 1 and arg(p, 0) != 2:
            return EBADF
        let s = p.space.read(arg(p, 1), arg(p, 2))
        if s == nil:
            return EFAULT
        console(p, s)
        return len(s)
    if nr == 20:
        return sys_writev(p, arg(p, 0), arg(p, 1), arg(p, 2))
    if nr == 60 or nr == 231:
        p.exit_code = arg(p, 0)
        return 0
    if nr == 9:   # mmap(addr, len, prot, flags, fd, off): anonymous only
        if arg(p, 4) != -1 and (arg(p, 3) & 0x20) == 0:
            return ENOSYS
        return p.mmap(arg(p, 1), 7)
    if nr == 25:   # mremap(old, oldlen, newlen, flags)
        return p.mremap(arg(p, 0), arg(p, 1), arg(p, 2), (arg(p, 3) & 1) != 0)
    if nr == 11:
        p.munmap(arg(p, 0), arg(p, 1))
        return 0
    if nr == 12:   # brk
        let want = arg(p, 0)
        if want > p.brk_base and want < p.brk_base + (256 << 20):
            if want > p.brk:
                p.add_region(p.brk & ~4095, (want + 4095) & ~4095, 7)
            p.brk = want
        return p.brk
    if nr == 158:   # arch_prctl(ARCH_SET_FS)
        if arg(p, 0) == 0x1002:
            hw.poke64(p.ctx + kproc.CTX_FSB, arg(p, 1))
            return 0
        return -22
    if nr == 218 or nr == 186 or nr == 39:   # set_tid_address / gettid / getpid
        return p.pid
    if nr == 10 or nr == 13 or nr == 14 or nr == 28 or nr == 202 or nr == 24 or nr == 131:
        return 0
    if nr == 16:
        return ENOTTY
    if nr == 228:   # clock_gettime
        let us = hw.ticks_us()
        p.space.write64(arg(p, 1), us // 1000000)
        p.space.write64(arg(p, 1) + 8, (us % 1000000) * 1000)
        return 0
    if nr == 318:   # getrandom
        let n = arg(p, 1)
        let x = hw.ticks_us() | 1
        for i in range(n):
            x = (x * 6364136223846793005 + 1442695040888963407)
            hw.poke8(p.space.translate(arg(p, 0) + i), (x >> 33) & 255)
        return n
    if nr == 1002:
        return sys_fb_map(p, arg(p, 0))
    if nr == 1003:
        return sys_input(p, arg(p, 0), arg(p, 1))
    if nr == 1010:   # shm_create(size, out): out = [id, address, bytes]
        let r = shm.create(p, arg(p, 0))
        if r[0] > 0:
            for i in range(3):
                p.space.write64(arg(p, 1) + i * 8, r[i])
        return r[0]
    if nr == 1011:   # shm_open(id, out): returns the address, out = bytes
        let va = shm.attach(p, arg(p, 0))
        if va > 0:
            p.space.write64(arg(p, 1), shm.size_of(arg(p, 0)))
        return va
    if nr == 1012:   # shm_close(address)
        return shm.detach(p, arg(p, 0))
    if nr == 1005:   # poweroff (gui process only)
        if not p.gui:
            return EPERM
        hw.poweroff()
    if nr == 1006:   # meminfo(out): [total, free] in bytes
        let m = hw.mem_info()
        p.space.write64(arg(p, 0), m[0])
        p.space.write64(arg(p, 0) + 8, kmem.free_count() * 4096)
        return 0
    if nr == 1008:   # rtc(out): year month day hour minute second
        let t = rtc.now()
        for i in range(6):
            p.space.write64(arg(p, 0) + i * 8, t[i])
        return 0
    if nr == 1009:   # reboot (gui process only)
        if not p.gui:
            return EPERM
        hw.reboot()
    if nr == 0:
        return 0
    if nr == 2 or nr == 4 or nr == 5 or nr == 21 or nr == 89 or nr == 257 or nr == 262:
        return ENOENT
    log("pid " .. to_string(p.pid) .. ": unsupported syscall " .. to_string(nr))
    return ENOSYS
