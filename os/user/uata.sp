# uata: a PIO driver for ATA hard disks (the legacy IDE ports 0x1F0 / 0x170), written in Sprint on top of uio (port I/O the kernel opens for the fsd driver
# process only). A Disk has the block-device interface SprintFS wants: read(n), write(n, data), flush(), blocks(), block_size() with 4096-byte blocks
# (eight 512-byte sectors). Polling only, LBA28 (up to 128 GiB), no DMA.
import uio
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
        let s = uio.inb(base + 7)
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
        uio.outb(self.base + 6, 0xE0 | (self.slave << 4) | ((lba >> 24) & 15))
        uio.outb(self.base + 2, count)
        uio.outb(self.base + 3, lba & 255)
        uio.outb(self.base + 4, (lba >> 8) & 255)
        uio.outb(self.base + 5, (lba >> 16) & 255)
    func read(self, n):
        if n < 0 or n >= self.blocks():
            fail("read past the end: block " .. to_string(n))
        let r = uio.ata_read(self.base, self.ctl, self.slave, n * PER_BLOCK, PER_BLOCK)
        if type(r) == "int":
            fail("read error " .. to_string(r) .. " at block " .. to_string(n))
        return r
    # k blocks from block n in one go
    func read_run(self, n, k):
        if n < 0 or n + k > self.blocks():
            fail("read past the end: block " .. to_string(n))
        let r = uio.ata_read(self.base, self.ctl, self.slave, n * PER_BLOCK, k * PER_BLOCK)
        if type(r) == "int":
            fail("read error " .. to_string(r) .. " at block " .. to_string(n))
        return r
    func write(self, n, data):
        if n < 0 or n >= self.blocks():
            fail("write past the end: block " .. to_string(n))
        let d = typed.u8(data) if type(data) == "array" else data
        let r = uio.ata_write(self.base, self.ctl, self.slave, n * PER_BLOCK, d)
        if r != 0:
            fail("write error " .. to_string(r) .. " at block " .. to_string(n))
    func flush(self):
        uio.outb(self.base + 6, 0xE0 | (self.slave << 4))
        uio.outb(self.base + 7, 0xE7)               # FLUSH CACHE
        wait(self.base, 0x80, 0, "flush")

# IDENTIFY one position; the Disk, or nil if nothing (or not a plain ATA disk) is there
func identify(base, ctl, slave):
    uio.outb(base + 6, 0xA0 | (slave << 4))
    for i in range(4):
        uio.inb(ctl)
    uio.outb(base + 2, 0)
    uio.outb(base + 3, 0)
    uio.outb(base + 4, 0)
    uio.outb(base + 5, 0)
    uio.outb(base + 7, 0xEC)
    if uio.inb(base + 7) == 0:
        return nil                                 # no device
    for i in range(500000):
        if (uio.inb(base + 7) & 0x80) == 0:
            break
    if uio.inb(base + 4) != 0 or uio.inb(base + 5) != 0:
        return nil                                 # ATAPI / SATA signature: not for this driver
    for i in range(500000):
        let s = uio.inb(base + 7)
        if (s & 0x01) != 0:
            return nil
        if (s & 0x08) != 0:
            break
    let id = []
    for w in range(256):
        id.append(uio.inw(base))
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
            if uio.inb(ch[0] + 7) == 0xFF:
                continue                           # a floating bus: no controller on this channel
            let d = identify(ch[0], ch[1], slave)
            if d != nil:
                found.append(d)
    return found
