# gpud: the GPU driver server. A user process (not part of the kernel) that drives a VirtIO-GPU (QEMU's virtio-vga / virtio-gpu-pci, 2D mode) with the
# registers and DMA memory the kernel lets it have, and serves other processes over messages as "gpu". It follows the 2D path of C-OS's virtio_gpu.c: a
# resource backed by guest memory, SET_SCANOUT, TRANSFER_TO_HOST_2D + RESOURCE_FLUSH to show a rectangle, and the cursor queue for a hardware pointer.
#
# Protocol (tab separated; "ok..." / "err<TAB>KIND<TAB>message" replies):
#   info                          -> ok<TAB>width<TAB>height<TAB>pitch<TAB>segment   the screen's pixel memory (0xXXRRGGBB words) as a shared segment
#   flush<TAB>x<TAB>y<TAB>w<TAB>h    (no reply) copy the rectangle to the host and show it
#   cursor_image<TAB>segment<TAB>hot_x<TAB>hot_y   a 24x24 canvas (0xFF00FF = transparent) shared by the client becomes the pointer image
#   cursor_move<TAB>x<TAB>y          (no reply)
#   quit
import io
import ipc
import uio
import psys

const VIRTIO_VENDOR = 0x1AF4
const GPU_DEVICE = 0x1050          # 0x1040 + virtio device id 16

func log(s):
    print("[gpud] " .. s)
    io.flush()

func align_up(v, a):
    return (v + a - 1) // a * a

# ---- PCI configuration space (mechanism 1) ---------------------------------------------------------------------
func cfg_addr(bdf, off):
    return 0x80000000 | (bdf[0] << 16) | (bdf[1] << 11) | (bdf[2] << 8) | (off & 0xFC)

func cfg_r32(bdf, off):
    uio.outl(0xCF8, cfg_addr(bdf, off))
    return uio.inl(0xCFC)

func cfg_w32(bdf, off, v):
    uio.outl(0xCF8, cfg_addr(bdf, off))
    uio.outl(0xCFC, v)

func cfg_r8(bdf, off):
    return (cfg_r32(bdf, off) >> ((off & 3) * 8)) & 255

func pci_find(vendor, device):
    for dev in range(32):
        for fn in range(8):
            let bdf = [0, dev, fn]
            let id = cfg_r32(bdf, 0)
            if id == 0xFFFFFFFF:
                if fn == 0:
                    break
                continue
            if (id & 0xFFFF) == vendor and (id >> 16) == device:
                return bdf
            if fn == 0 and (cfg_r8(bdf, 0x0E) & 0x80) == 0:
                break
    return nil

# ---- virtio over PCI (the modern, memory-mapped interface) -----------------------------------------------------------
const ST_ACK = 1
const ST_DRIVER = 2
const ST_DRIVER_OK = 4
const ST_FEATURES_OK = 8

class Virtio:
    let common = 0
    let notify = 0
    let notify_mult = 0
    let bdf = nil
    func init(self, bdf):
        self.bdf = bdf
        let caps = {}
        let ptr = cfg_r8(bdf, 0x34) & 0xFC
        let guard = 0
        while ptr != 0 and guard < 48:
            guard += 1
            if cfg_r8(bdf, ptr) == 9:
                let t = cfg_r8(bdf, ptr + 3)
                caps[to_string(t)] = {bar: cfg_r8(bdf, ptr + 4), off: cfg_r32(bdf, ptr + 8), len: cfg_r32(bdf, ptr + 12), mult: cfg_r32(bdf, ptr + 16) if t == 2 else 0}
            ptr = cfg_r8(bdf, ptr + 1) & 0xFC
        if not ("1" in caps) or not ("2" in caps):
            throw error("OSError", "virtio: capabilities missing")
        cfg_w32(bdf, 4, (cfg_r32(bdf, 4) & 0xFFFF) | 6)       # memory space + bus master
        let bars = {}
        func bar_va(c):
            let k = to_string(c.bar)
            let need = c.off + c.len
            if k in bars:
                if bars[k][1] >= need:
                    return bars[k][0]
            let lo = cfg_r32(bdf, 0x10 + 4 * c.bar)
            let phys = lo & 0xFFFFFFF0
            if ((lo >> 1) & 3) == 2:
                phys = phys | (cfg_r32(bdf, 0x14 + 4 * c.bar) << 32)
            let size = align_up(need, 4096)
            bars[k] = [uio.mmio_map(phys, size), size]
            return bars[k][0]
        self.common = bar_va(caps["1"]) + caps["1"].off
        self.notify = bar_va(caps["2"]) + caps["2"].off
        self.notify_mult = caps["2"].mult
    func status(self):
        return uio.peek8(self.common + 20)
    func set_status(self, v):
        uio.poke8(self.common + 20, v)
    func add_status(self, v):
        self.set_status(self.status() | v)
    func reset(self):
        self.set_status(0)
        for i in range(1000):
            if self.status() == 0:
                break
    # VERSION_1 only: no optional features (no 3D)
    func negotiate(self):
        uio.poke32(self.common + 0, 1)
        let hi = uio.peek32(self.common + 4)
        if (hi & 1) == 0:
            return false
        uio.poke32(self.common + 8, 0)
        uio.poke32(self.common + 12, 0)
        uio.poke32(self.common + 8, 1)
        uio.poke32(self.common + 12, 1)
        self.add_status(ST_FEATURES_OK)
        return (self.status() & ST_FEATURES_OK) != 0

class Queue:
    let dev = nil
    let index = 0
    let size = 0
    let blk = nil         # DMA block: rings in the first page, request / response buffers in the second
    let avail = 0
    let used = 0
    let last_used = 0
    let avail_idx = 0
    let notify_addr = 0
    func init(self, dev, index, want):
        self.dev = dev
        self.index = index
        let c = dev.common
        uio.poke16(c + 22, index)
        let max = uio.peek16(c + 24)
        if max == 0:
            throw error("OSError", "virtio: queue " .. to_string(index) .. " is not there")
        self.size = max if max < want else want
        uio.poke16(c + 24, self.size)
        self.blk = uio.dma_alloc(8192)
        let base = self.blk[1]
        let phys = self.blk[2]
        self.avail = base + 16 * self.size
        self.used = base + align_up(16 * self.size + 6 + 2 * self.size, 4)
        uio.poke64(c + 32, phys)
        uio.poke64(c + 40, phys + 16 * self.size)
        uio.poke64(c + 48, phys + align_up(16 * self.size + 6 + 2 * self.size, 4))
        uio.poke16(c + 28, 1)
        self.notify_addr = dev.notify + uio.peek16(c + 30) * dev.notify_mult
    func req_va(self):
        return self.blk[1] + 4096
    func resp_va(self):
        return self.blk[1] + 4096 + 2048
    # submit the request already written at req_va (req_len bytes) and, when resp_len > 0, wait for the device to fill resp_va
    func submit(self, req_len, resp_len):
        let base = self.blk[1]
        let rphys = self.blk[2] + 4096
        let respphys = self.blk[2] + 4096 + 2048
        uio.poke64(base, rphys)
        uio.poke32(base + 8, req_len)
        if resp_len > 0:
            uio.poke16(base + 12, 1)               # NEXT
            uio.poke16(base + 14, 1)
            uio.poke64(base + 16, respphys)
            uio.poke32(base + 24, resp_len)
            uio.poke16(base + 28, 2)               # WRITE
            uio.poke16(base + 30, 0)
        else:
            uio.poke16(base + 12, 0)
            uio.poke16(base + 14, 0)
        uio.poke16(self.avail + 4 + 2 * (self.avail_idx % self.size), 0)
        self.avail_idx = (self.avail_idx + 1) & 0xFFFF
        uio.poke16(self.avail + 2, self.avail_idx)
        uio.poke16(self.notify_addr, self.index)
        for i in range(2000000):
            if uio.peek16(self.used + 2) != self.last_used:
                self.last_used = (self.last_used + 1) & 0xFFFF
                return true
        return false

# ---- the GPU --------------------------------------------------------------------------------------------------------------
const CMD_GET_DISPLAY_INFO = 0x100
const CMD_RESOURCE_CREATE_2D = 0x101
const CMD_SET_SCANOUT = 0x103
const CMD_RESOURCE_FLUSH = 0x104
const CMD_TRANSFER_TO_HOST_2D = 0x105
const CMD_ATTACH_BACKING = 0x106
const CMD_UPDATE_CURSOR = 0x300
const CMD_MOVE_CURSOR = 0x301
const RESP_OK = 0x1100
const RESP_OK_DISPLAY_INFO = 0x1101
const FMT_B8G8R8A8 = 1
const FMT_B8G8R8X8 = 2
const RES_SCREEN = 1
const RES_CURSOR = 2

let vio = nil
let ctrl = nil
let curq = nil
let screen = nil        # {w, h, blk}
let cursor_blk = nil

func start_cmd(q, type):
    let r = q.req_va()
    for i in range(0, 24, 4):
        uio.poke32(r + i, 0)
    uio.poke32(r, type)
    return r

# sends a command on the control queue and checks for a plain OK
func command(req_len):
    if not ctrl.submit(req_len, 24):
        return false
    return uio.peek32(ctrl.resp_va()) == RESP_OK

func gpu_open():
    let bdf = pci_find(VIRTIO_VENDOR, GPU_DEVICE)
    if bdf == nil:
        return "no VirtIO-GPU on the PCI bus"
    vio = Virtio(bdf)
    vio.reset()
    vio.add_status(ST_ACK)
    vio.add_status(ST_DRIVER)
    if not vio.negotiate():
        return "feature negotiation failed"
    ctrl = Queue(vio, 0, 64)
    try:
        curq = Queue(vio, 1, 16)
    catch e:
        curq = nil
    vio.add_status(ST_DRIVER_OK)
    # the display's size
    let w = 1024
    let h = 768
    let r = start_cmd(ctrl, CMD_GET_DISPLAY_INFO)
    if ctrl.submit(24, 24 + 16 * 24) and uio.peek32(ctrl.resp_va()) == RESP_OK_DISPLAY_INFO:
        let pm = ctrl.resp_va() + 24
        if uio.peek32(pm + 16) != 0 and uio.peek32(pm + 8) != 0 and uio.peek32(pm + 12) != 0:
            w = uio.peek32(pm + 8)
            h = uio.peek32(pm + 12)
    let blk = uio.dma_alloc(w * h * 4)
    # RESOURCE_CREATE_2D
    r = start_cmd(ctrl, CMD_RESOURCE_CREATE_2D)
    uio.poke32(r + 24, RES_SCREEN)
    uio.poke32(r + 28, FMT_B8G8R8X8)
    uio.poke32(r + 32, w)
    uio.poke32(r + 36, h)
    if not command(40):
        return "RESOURCE_CREATE_2D failed"
    # RESOURCE_ATTACH_BACKING: one contiguous entry
    r = start_cmd(ctrl, CMD_ATTACH_BACKING)
    uio.poke32(r + 24, RES_SCREEN)
    uio.poke32(r + 28, 1)
    uio.poke64(r + 32, blk[2])
    uio.poke32(r + 40, w * h * 4)
    uio.poke32(r + 44, 0)
    if not command(48):
        return "RESOURCE_ATTACH_BACKING failed"
    # SET_SCANOUT
    r = start_cmd(ctrl, CMD_SET_SCANOUT)
    uio.poke32(r + 24, 0)
    uio.poke32(r + 28, 0)
    uio.poke32(r + 32, w)
    uio.poke32(r + 36, h)
    uio.poke32(r + 40, 0)
    uio.poke32(r + 44, RES_SCREEN)
    if not command(48):
        return "SET_SCANOUT failed"
    screen = {w: w, h: h, blk: blk}
    return nil

func flush(x, y, w, h):
    if x < 0:
        w += x
        x = 0
    if y < 0:
        h += y
        y = 0
    if x >= screen.w or y >= screen.h:
        return nil
    if x + w > screen.w:
        w = screen.w - x
    if y + h > screen.h:
        h = screen.h - y
    if w <= 0 or h <= 0:
        return nil
    let r = start_cmd(ctrl, CMD_TRANSFER_TO_HOST_2D)
    uio.poke32(r + 24, x)
    uio.poke32(r + 28, y)
    uio.poke32(r + 32, w)
    uio.poke32(r + 36, h)
    uio.poke64(r + 40, y * screen.w * 4 + x * 4)
    uio.poke32(r + 48, RES_SCREEN)
    uio.poke32(r + 52, 0)
    if not command(56):
        return nil
    r = start_cmd(ctrl, CMD_RESOURCE_FLUSH)
    uio.poke32(r + 24, x)
    uio.poke32(r + 28, y)
    uio.poke32(r + 32, w)
    uio.poke32(r + 36, h)
    uio.poke32(r + 40, RES_SCREEN)
    uio.poke32(r + 44, 0)
    command(48)

# ---- the hardware cursor ------------------------------------------------------------------------------------------------
let cursor_ready = false
let cursor_x = 0
let cursor_y = 0
let cursor_hot = [0, 0]

func cursor_cmd(type, res):
    if curq == nil:
        return nil
    let r = start_cmd(curq, type)
    uio.poke32(r + 24, 0)                     # scanout 0
    uio.poke32(r + 28, cursor_x)
    uio.poke32(r + 32, cursor_y)
    uio.poke32(r + 36, 0)
    uio.poke32(r + 40, res)
    uio.poke32(r + 44, cursor_hot[0])
    uio.poke32(r + 48, cursor_hot[1])
    uio.poke32(r + 52, 0)
    curq.submit(56, 0)

# the pointer image: a 24x24 canvas of 0xRRGGBB words, 0xFF00FF transparent, placed into a 64x64 ARGB resource
func set_cursor_image(src_va, hot_x, hot_y):
    if curq == nil:
        return false
    if cursor_blk == nil:
        cursor_blk = uio.dma_alloc(64 * 64 * 4)
        let r = start_cmd(ctrl, CMD_RESOURCE_CREATE_2D)
        uio.poke32(r + 24, RES_CURSOR)
        uio.poke32(r + 28, FMT_B8G8R8A8)
        uio.poke32(r + 32, 64)
        uio.poke32(r + 36, 64)
        if not command(40):
            return false
        r = start_cmd(ctrl, CMD_ATTACH_BACKING)
        uio.poke32(r + 24, RES_CURSOR)
        uio.poke32(r + 28, 1)
        uio.poke64(r + 32, cursor_blk[2])
        uio.poke32(r + 40, 64 * 64 * 4)
        uio.poke32(r + 44, 0)
        if not command(48):
            return false
    let base = cursor_blk[1]
    for i in range(64 * 64):
        uio.poke32(base + 4 * i, 0)
    for y in range(24):
        for x in range(24):
            let px = uio.peek32(src_va + 4 * (y * 24 + x)) & 0xFFFFFF
            if px != 0xFF00FF:
                uio.poke32(base + 4 * (y * 64 + x), 0xFF000000 | px)
    let r = start_cmd(ctrl, CMD_TRANSFER_TO_HOST_2D)
    uio.poke32(r + 24, 0)
    uio.poke32(r + 28, 0)
    uio.poke32(r + 32, 64)
    uio.poke32(r + 36, 64)
    uio.poke64(r + 40, 0)
    uio.poke32(r + 48, RES_CURSOR)
    uio.poke32(r + 52, 0)
    if not command(56):
        return false
    cursor_hot = [hot_x, hot_y]
    cursor_ready = true
    cursor_cmd(CMD_UPDATE_CURSOR, RES_CURSOR)
    return true

# ---- the service ---------------------------------------------------------------------------------------------------------
let problem = gpu_open()
if problem != nil:
    log("no GPU: " .. problem)
else:
    log("VirtIO-GPU ready: " .. to_string(screen.w) .. "x" .. to_string(screen.h) .. ", control queue " .. to_string(ctrl.size) .. ", cursor queue " .. ("yes" if curq != nil else "no"))
ipc.register("gpu")
let attached = {}
let running = true
while running:
    io.flush()
    let m = ipc.recv_from()
    let src = m[0]
    let q = m[1].split("\t")
    let op = q[0]
    if op == "quit":
        ipc.send(src, "ok")
        running = false
    elif problem != nil:
        if op == "info":
            ipc.send(src, "err\tENODEV\t" .. problem)
    elif op == "info":
        ipc.send(src, "ok\t" .. to_string(screen.w) .. "\t" .. to_string(screen.h) .. "\t" .. to_string(screen.w * 4) .. "\t" .. to_string(screen.blk[0]))
    elif op == "flush":
        flush(to_int(q[1]), to_int(q[2]), to_int(q[3]), to_int(q[4]))
    elif op == "cursor_image":
        let seg = ipc.shm_open(to_int(q[1]))
        let good = set_cursor_image(seg[0], to_int(q[2]), to_int(q[3]))
        ipc.shm_close(seg[0])
        ipc.send(src, "ok" if good else "err\tEIO\tcursor image failed")
    elif op == "cursor_move":
        cursor_x = to_int(q[1])
        cursor_y = to_int(q[2])
        if cursor_ready:
            cursor_cmd(CMD_MOVE_CURSOR, RES_CURSOR)
log("bye")
