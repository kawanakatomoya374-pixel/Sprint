# uvblk: a virtio-blk driver (PCI, the legacy/transitional interface QEMU, VirtualBox and most hypervisors offer), written in Sprint on top of uio.
# One request queue, polled; requests of up to 128 blocks go in a single descriptor chain with the data DMAed straight into a buffer, so a read costs
# one device round trip instead of a port-I/O instruction per word like the ATA PIO driver. A Disk has the same interface as uata.Disk
# (read, read_run, write, flush, blocks, block_size with 4096-byte blocks), so SprintFS runs on either.
import uio
import typed

const BLOCK = 4096
const MAXRUN = 128                 # blocks per request (512 KiB)

const R_HOST_FEATURES = 0
const R_GUEST_FEATURES = 4
const R_QUEUE_PFN = 8
const R_QUEUE_SIZE = 12
const R_QUEUE_SEL = 14
const R_QUEUE_NOTIFY = 16
const R_STATUS = 18
const R_CONFIG = 20

const F_FLUSH = 1 << 9
const F_BLK_SIZE = 1 << 6

func fail(msg):
    throw error("IOError", "virtio-blk: " .. msg)

func cfg_addr(bdf, off):
    return 0x80000000 | (bdf[0] << 16) | (bdf[1] << 11) | (bdf[2] << 8) | (off & 0xFC)
func cfg_r32(bdf, off):
    uio.outl(0xCF8, cfg_addr(bdf, off))
    return uio.inl(0xCFC)
func cfg_w32(bdf, off, v):
    uio.outl(0xCF8, cfg_addr(bdf, off))
    uio.outl(0xCFC, v)

export class Disk:
    let io = 0
    let sectors = 0
    let model = "virtio-blk"
    let qsize = 0
    let ring = nil            # DMA: descriptors, available ring, used ring
    let used_off = 0
    let req = nil             # DMA: request header (16 bytes), status byte, then the data buffer
    let avail_idx = 0
    let flush_ok = false
    func init(self, io, sectors, qsize, ring, used_off, req, flush_ok):
        self.io = io
        self.sectors = sectors
        self.qsize = qsize
        self.ring = ring
        self.used_off = used_off
        self.req = req
        self.flush_ok = flush_ok
    func blocks(self):
        return self.sectors // 8
    func block_size(self):
        return BLOCK
    # one request: kind 0 read, 1 write, 4 flush; sector; the data buffer holds `bytes` bytes
    func submit(self, kind, sector, bytes):
        let h = self.req[1]
        let hp = self.req[2]
        uio.poke32(h, kind)
        uio.poke32(h + 4, 0)
        uio.poke64(h + 8, sector)
        uio.poke8(h + 16, 0xFF)
        let d = self.ring[1]
        let dp = self.ring[2]
        # descriptor 0: header; 1: data (if any); 2 (or 1 for a flush): status
        uio.poke64(d, hp)
        uio.poke32(d + 8, 16)
        let last = 1
        if bytes > 0:
            uio.poke16(d + 12, 1)                     # NEXT
            uio.poke16(d + 14, 1)
            uio.poke64(d + 16, hp + 64)
            uio.poke32(d + 24, bytes)
            uio.poke16(d + 28, (2 | 1) if kind == 0 else 1)     # WRITE (device writes) for a read; NEXT
            uio.poke16(d + 30, 2)
            last = 2
        else:
            uio.poke16(d + 12, 1)
            uio.poke16(d + 14, 1)
        uio.poke64(d + 16 * last, hp + 16)
        uio.poke32(d + 16 * last + 8, 1)
        uio.poke16(d + 16 * last + 12, 2)             # WRITE: the status byte
        uio.poke16(d + 16 * last + 14, 0)
        let av = d + 16 * self.qsize
        uio.poke16(av + 4 + 2 * (self.avail_idx % self.qsize), 0)
        self.avail_idx = (self.avail_idx + 1) & 0xFFFF
        uio.poke16(av + 2, self.avail_idx)
        uio.outw(self.io + R_QUEUE_NOTIFY, 0)
        let used = d + self.used_off
        let spins = 0
        while (uio.peek16(used + 2) & 0xFFFF) != self.avail_idx:
            spins += 1
            if spins > 3000000:
                fail("the device did not answer")
        let st = uio.peek8(h + 16)
        if st != 0:
            fail("request failed (status " .. to_string(st) .. ")")
    func read_run(self, n, k):
        if n < 0 or n + k > self.blocks():
            fail("read past the end: block " .. to_string(n))
        if k <= MAXRUN:
            self.submit(0, n * 8, k * BLOCK)
            return uio.mem_get(self.req[1] + 64, k * BLOCK)
        let parts = []
        let done = 0
        while done < k:
            let m = k - done
            if m > MAXRUN:
                m = MAXRUN
            self.submit(0, (n + done) * 8, m * BLOCK)
            parts.append(uio.mem_get(self.req[1] + 64, m * BLOCK))
            done += m
        let out = typed.u8(k * BLOCK)
        let at = 0
        for p in parts:
            for i in range(len(p)):
                out[at + i] = p[i]
            at += len(p)
        return out
    func read(self, n):
        return self.read_run(n, 1)
    func write(self, n, data):
        if n < 0 or n >= self.blocks():
            fail("write past the end: block " .. to_string(n))
        let d = typed.u8(data) if type(data) == "array" else data
        if len(d) == 0 or len(d) % BLOCK != 0 or len(d) > MAXRUN * BLOCK:
            fail("write: expected 1.." .. to_string(MAXRUN) .. " whole blocks")
        uio.mem_put(self.req[1] + 64, d)
        self.submit(1, n * 8, len(d))
    func flush(self):
        if self.flush_ok:
            self.submit(4, 0, 0)

# every virtio-blk device on bus 0
export func probe():
    let found = []
    for dev in range(32):
        for fn in range(8):
            let bdf = [0, dev, fn]
            let id = cfg_r32(bdf, 0)
            if id == 0xFFFFFFFF:
                if fn == 0:
                    break
                continue
            if (id & 0xFFFF) == 0x1AF4 and (id >> 16) == 0x1001:
                let d = open(bdf)
                if d != nil:
                    found.append(d)
            if fn == 0 and ((cfg_r32(bdf, 0x0C) >> 16) & 0x80) == 0:
                break
    return found

func open(bdf):
    cfg_w32(bdf, 4, (cfg_r32(bdf, 4) & 0xFFFF) | 5)           # I/O space + bus master
    let bar = cfg_r32(bdf, 0x10)
    if (bar & 1) == 0:
        return nil
    let io = bar & 0xFFFC
    print("[fsd] virtio-blk at PCI " .. to_string(bdf[1]) .. ":" .. to_string(bdf[2]) .. ", I/O ports " .. to_string(io))
    uio.outb(io + R_STATUS, 0)                                 # reset
    uio.outb(io + R_STATUS, 1 | 2)                             # acknowledge, driver
    let feat = uio.inl(io + R_HOST_FEATURES)
    uio.outl(io + R_GUEST_FEATURES, feat & F_FLUSH)
    uio.outw(io + R_QUEUE_SEL, 0)
    let qsize = uio.inw(io + R_QUEUE_SIZE)
    if qsize == 0:
        return nil
    let desc_bytes = 16 * qsize
    let avail_bytes = 6 + 2 * qsize
    let used_off = (desc_bytes + avail_bytes + 4095) & ~4095
    let total = used_off + ((6 + 8 * qsize + 4095) & ~4095)
    let ring = uio.dma_alloc(total)
    for i in range(total // 8):
        uio.poke64(ring[1] + 8 * i, 0)
    let req = uio.dma_alloc(64 + MAXRUN * BLOCK)
    uio.outl(io + R_QUEUE_PFN, ring[2] >> 12)
    uio.outb(io + R_STATUS, 1 | 2 | 4)                         # driver ok
    let cap = uio.inl(io + R_CONFIG) | (uio.inl(io + R_CONFIG + 4) << 32)
    print("[fsd] virtio-blk ready: " .. to_string(cap) .. " sectors")
    return Disk(io, cap, qsize, ring, used_off, req, (feat & F_FLUSH) != 0)
