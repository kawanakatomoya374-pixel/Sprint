# ata: a PIO driver for ATA hard disks (the legacy IDE ports 0x1F0 / 0x170), written in Sprint on top of hw.inb / hw.inw / hw.outb / hw.outw.
# A Disk has the block-device interface SprintFS wants: read(n), write(n, data), flush(), blocks(), block_size() with 4096-byte blocks
# (eight 512-byte sectors). Polling only, LBA28 (up to 128 GiB), no DMA: simple and enough to hold the root file system.
import hw
import typed
import str

const SECTOR = 512
const BLOCK = 4096
const PER_BLOCK = 8

func fail(msg):
    throw error("IOError", "ata: " .. msg)

# waits until (status & mask) == want, and returns the status; throws on timeout or a device error
func wait(base, mask, want, what):
    for i in range(2000000):
        let s = hw.inb(base + 7)
        if (s & 0x01) != 0 and (s & 0x80) == 0:
            fail(what .. ": device error")
        if (s & mask) == want:
            return s
    fail(what .. ": timed out")

export class Disk:
    let base = 0
    let ctl = 0
    let slave = 0
    let sectors = 0
    let model = ""
    func init(self, base, ctl, slave, sectors, model):
        self.base = base
        self.ctl = ctl
        self.slave = slave
        self.sectors = sectors
        self.model = model
    func blocks(self):
        return self.sectors // PER_BLOCK
    func block_size(self):
        return BLOCK
    func select(self, lba, count):
        hw.outb(self.base + 6, 0xE0 | (self.slave << 4) | ((lba >> 24) & 15))
        hw.outb(self.base + 2, count)
        hw.outb(self.base + 3, lba & 255)
        hw.outb(self.base + 4, (lba >> 8) & 255)
        hw.outb(self.base + 5, (lba >> 16) & 255)
    func read(self, n):
        if n < 0 or n >= self.blocks():
            fail("read past the end: block " .. to_string(n))
        let out = typed.u8(BLOCK)
        let lba = n * PER_BLOCK
        for s in range(PER_BLOCK):
            wait(self.base, 0x80, 0, "read")
            self.select(lba + s, 1)
            hw.outb(self.base + 7, 0x20)
            hw.inb(self.ctl)                       # 400 ns of settling: four reads of the alternate status
            hw.inb(self.ctl)
            hw.inb(self.ctl)
            hw.inb(self.ctl)
            wait(self.base, 0x88, 0x08, "read")
            for w in range(256):
                let v = hw.inw(self.base)
                out[s * SECTOR + 2 * w] = v & 255
                out[s * SECTOR + 2 * w + 1] = v >> 8
        return out
    func write(self, n, data):
        if n < 0 or n >= self.blocks():
            fail("write past the end: block " .. to_string(n))
        let lba = n * PER_BLOCK
        for s in range(PER_BLOCK):
            wait(self.base, 0x80, 0, "write")
            self.select(lba + s, 1)
            hw.outb(self.base + 7, 0x30)
            hw.inb(self.ctl)
            hw.inb(self.ctl)
            hw.inb(self.ctl)
            hw.inb(self.ctl)
            wait(self.base, 0x88, 0x08, "write")
            for w in range(256):
                hw.outw(self.base, data[s * SECTOR + 2 * w] | (data[s * SECTOR + 2 * w + 1] << 8))
        wait(self.base, 0x80, 0, "write")
    func flush(self):
        hw.outb(self.base + 6, 0xE0 | (self.slave << 4))
        hw.outb(self.base + 7, 0xE7)               # FLUSH CACHE
        wait(self.base, 0x80, 0, "flush")

# IDENTIFY one position; the Disk, or nil if nothing (or not a plain ATA disk) is there
func identify(base, ctl, slave):
    hw.outb(base + 6, 0xA0 | (slave << 4))
    for i in range(4):
        hw.inb(ctl)
    hw.outb(base + 2, 0)
    hw.outb(base + 3, 0)
    hw.outb(base + 4, 0)
    hw.outb(base + 5, 0)
    hw.outb(base + 7, 0xEC)
    if hw.inb(base + 7) == 0:
        return nil                                 # no device
    for i in range(500000):
        if (hw.inb(base + 7) & 0x80) == 0:
            break
    if hw.inb(base + 4) != 0 or hw.inb(base + 5) != 0:
        return nil                                 # ATAPI / SATA signature: not for this driver
    for i in range(500000):
        let s = hw.inb(base + 7)
        if (s & 0x01) != 0:
            return nil
        if (s & 0x08) != 0:
            break
    let id = []
    for w in range(256):
        id.append(hw.inw(base))
    let sectors = id[60] | (id[61] << 16)
    if sectors == 0:
        return nil
    let model = ""
    let chars = typed.u8(40)
    for w in range(20):
        chars[2 * w] = id[27 + w] >> 8
        chars[2 * w + 1] = id[27 + w] & 255
    model = str.from_bytes(chars).trim()
    return Disk(base, ctl, slave, sectors, model)


# every ATA disk found on the two legacy channels
export func probe():
    let found = []
    for ch in [[0x1F0, 0x3F6], [0x170, 0x376]]:
        for slave in [0, 1]:
            if hw.inb(ch[0] + 7) == 0xFF:
                continue                           # a floating bus: no controller on this channel
            let d = identify(ch[0], ch[1], slave)
            if d != nil:
                found.append(d)
    return found
