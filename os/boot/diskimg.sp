# diskimg: a GPT disk image with one EFI System Partition holding a FAT32 file system, written in Sprint.
#
#   let d = diskimg.Disk(volume_sectors)               # volume of `volume_sectors` 512-byte sectors, 1 sector per cluster
#   let efi = d.mkdir(d.root, "EFI")                   # short (8.3) names only
#   d.write_file(d.root, "SPRINTOS.BIN", bytes)        # bytes: array or typed.u8
#   let image = d.finish()                             # typed.u8 of the whole disk (protective MBR, GPT, ESP, backup GPT)
import typed

const SECTOR = 512
const PART_START = 2048          # first LBA of the partition (1 MiB aligned)

let CRC_TABLE = []
func crc_init():
    for n in range(256):
        let c = n
        for k in range(8):
            if (c & 1) == 1:
                c = 0xedb88320 ^ (c >> 1)
            else:
                c = c >> 1
        CRC_TABLE.append(c)
crc_init()

export func crc32(buf, lo, hi):
    let c = 0xffffffff
    for i in range(lo, hi):
        c = CRC_TABLE[(c ^ buf[i]) & 255] ^ (c >> 8)
    return (~c) & 0xffffffff

func put16(b, o, v):
    b[o] = v & 255
    b[o + 1] = (v >> 8) & 255

func put32(b, o, v):
    for i in range(4):
        b[o + i] = (v >> (8 * i)) & 255

func put64(b, o, v):
    put32(b, o, v & 0xffffffff)
    put32(b, o + 4, (v >> 32) & 0xffffffff)

func puts(b, o, s):
    for i in range(len(s)):
        b[o + i] = s[i]

# an 8.3 name ("BOOTX64.EFI") as the 11 padded bytes of a directory entry
func short_name(name):
    let dot = name.find(".")
    let base = name if dot < 0 else name.slice(0, dot)
    let ext = "" if dot < 0 else name.slice(dot + 1, len(name))
    if len(base) > 8 or len(ext) > 3 or len(base) == 0:
        throw error("ValueError", "'" .. name .. "' is not an 8.3 name")
    return (base .. " ".repeat(8 - len(base)) .. ext .. " ".repeat(3 - len(ext))).upper()

const DATE = ((2026 - 1980) << 9) | (1 << 5) | 1

export class Disk:
    let vol = nil          # the FAT32 volume (typed.u8)
    let sectors = 0
    let fat_sectors = 0
    let first_data = 0
    let next_cluster = 3
    let root = 2
    let fat_off = 0
    let nclusters = 0

    func init(self, volume_sectors):
        self.sectors = volume_sectors
        self.vol = typed.u8(volume_sectors * SECTOR)
        self.fat_sectors = (volume_sectors + 127) // 128
        let reserved = 32
        self.first_data = reserved + 2 * self.fat_sectors
        self.nclusters = volume_sectors - self.first_data
        if self.nclusters < 65525:
            throw error("ValueError", "a FAT32 volume needs at least 65525 clusters (use more sectors)")
        self.fat_off = reserved * SECTOR
        let v = self.vol
        # boot sector (BPB)
        puts(v, 0, [0xeb, 0x58, 0x90])
        puts(v, 3, "SPRINTOS")
        put16(v, 11, SECTOR)
        v[13] = 1
        put16(v, 14, reserved)
        v[16] = 2
        v[21] = 0xf8
        put16(v, 24, 32)
        put16(v, 26, 64)
        put32(v, 28, PART_START)
        put32(v, 32, volume_sectors)
        put32(v, 36, self.fat_sectors)
        put32(v, 44, 2)
        put16(v, 48, 1)
        put16(v, 50, 6)
        v[64] = 0x80
        v[66] = 0x29
        put32(v, 67, 0x53505254)
        puts(v, 71, "SPRINT OS  ")
        puts(v, 82, "FAT32   ")
        put16(v, 510, 0xaa55)
        # FSInfo
        put32(v, SECTOR, 0x41615252)
        put32(v, SECTOR + 484, 0x61417272)
        put32(v, SECTOR + 488, 0xffffffff)
        put32(v, SECTOR + 492, 0xffffffff)
        put32(v, SECTOR + 508, 0xaa550000)
        # FAT: media, end-of-chain markers, the root directory's single cluster
        put32(v, self.fat_off, 0x0ffffff8)
        put32(v, self.fat_off + 4, 0x0fffffff)
        put32(v, self.fat_off + 8, 0x0fffffff)

    func cluster_off(self, c):
        return (self.first_data + (c - 2)) * SECTOR

    func fat_set(self, c, val):
        put32(self.vol, self.fat_off + c * 4, val)
        put32(self.vol, self.fat_off + self.fat_sectors * SECTOR + c * 4, val)   # the second FAT copy

    # `n` contiguous clusters chained in the FAT; returns the first
    func alloc(self, n):
        let first = self.next_cluster
        if first + n >= self.nclusters + 2:
            throw error("MemoryError", "the FAT32 volume is full")
        for i in range(n):
            let c = first + i
            self.fat_set(c, 0x0fffffff if i == n - 1 else c + 1)
        self.next_cluster += n
        return first

    func add_entry(self, dir, name, attr, cluster, size):
        let off = self.cluster_off(dir)
        let end = off + SECTOR
        let v = self.vol
        let e = off
        while e < end and v[e] != 0:
            e += 32
        if e >= end:
            throw error("MemoryError", "directory full")
        puts(v, e, short_name(name))
        v[e + 11] = attr
        put16(v, e + 14, 0)
        put16(v, e + 16, DATE)
        put16(v, e + 18, DATE)
        put16(v, e + 20, (cluster >> 16) & 0xffff)
        put16(v, e + 22, 0)
        put16(v, e + 24, DATE)
        put16(v, e + 26, cluster & 0xffff)
        put32(v, e + 28, size)

    func mkdir(self, parent, name):
        let c = self.alloc(1)
        self.add_entry(parent, name, 0x10, c, 0)
        let off = self.cluster_off(c)
        puts(self.vol, off, ".          ")
        self.vol[off + 11] = 0x10
        put16(self.vol, off + 20, (c >> 16) & 0xffff)
        put16(self.vol, off + 26, c & 0xffff)
        puts(self.vol, off + 32, "..         ")
        self.vol[off + 32 + 11] = 0x10
        let p = 0 if parent == 2 else parent
        put16(self.vol, off + 32 + 20, (p >> 16) & 0xffff)
        put16(self.vol, off + 32 + 26, p & 0xffff)
        for e in [off, off + 32]:
            put16(self.vol, e + 16, DATE)
            put16(self.vol, e + 18, DATE)
            put16(self.vol, e + 24, DATE)
        return c

    func write_file(self, dir, name, data):
        let n = len(data)
        let clusters = (n + SECTOR - 1) // SECTOR
        let c = self.alloc(clusters if clusters > 0 else 1)
        let off = self.cluster_off(c)
        let v = self.vol
        for i in range(n):
            v[off + i] = data[i]
        self.add_entry(dir, name, 0x20, c, n)

    # protective MBR + GPT + the volume + the backup GPT
    func finish(self):
        # the backup boot sector and FSInfo (sectors 6 and 7)
        for i in range(SECTOR):
            self.vol[6 * SECTOR + i] = self.vol[i]
            self.vol[7 * SECTOR + i] = self.vol[SECTOR + i]
        let total = PART_START + self.sectors + 34
        let img = typed.u8(total * SECTOR)
        # protective MBR: one 0xEE partition covering the disk
        let m = 446
        img[m + 4] = 0xee
        put32(img, m + 8, 1)
        put32(img, m + 12, total - 1)
        put16(img, 510, 0xaa55)
        # the partition entry (EFI System Partition)
        let ent = 2 * SECTOR
        puts(img, ent, [0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b])
        puts(img, ent + 16, [0x53, 0x70, 0x72, 0x69, 0x6e, 0x74, 0x4f, 0x53, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        put64(img, ent + 32, PART_START)
        put64(img, ent + 40, PART_START + self.sectors - 1)
        let name = "EFI System"
        for i in range(len(name)):
            img[ent + 56 + i * 2] = name[i]
        let entries_crc = crc32(img, 2 * SECTOR, 2 * SECTOR + 128 * 128)
        # the volume
        let vb = PART_START * SECTOR
        for i in range(self.sectors * SECTOR):
            img[vb + i] = self.vol[i]
        # backup entries (copy), then both headers
        let bk = (total - 33) * SECTOR
        for i in range(128 * 128):
            img[bk + i] = img[2 * SECTOR + i]
        for which in [0, 1]:
            let h = SECTOR if which == 0 else (total - 1) * SECTOR
            puts(img, h, "EFI PART")
            put32(img, h + 8, 0x00010000)
            put32(img, h + 12, 92)
            put64(img, h + 24, 1 if which == 0 else total - 1)
            put64(img, h + 32, total - 1 if which == 0 else 1)
            put64(img, h + 40, 34)
            put64(img, h + 48, total - 34)
            puts(img, h + 56, [0x53, 0x70, 0x72, 0x69, 0x6e, 0x74, 0x44, 0x69, 0x73, 0x6b, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
            put64(img, h + 72, 2 if which == 0 else total - 33)
            put32(img, h + 80, 128)
            put32(img, h + 84, 128)
            put32(img, h + 88, entries_crc)
            put32(img, h + 16, crc32(img, h, h + 92))
        return img
