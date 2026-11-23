# sprintfs: SprintFS, a journaling file system designed and written entirely in Sprint.
#
#   import sprintfs
#   let dev = sprintfs.MemDevice(2048, 4096)          # 2048 blocks of 4096 bytes in memory (or sprintfs.FileDevice, see below)
#   sprintfs.mkfs(dev, {label: "data"})
#   let fs = sprintfs.mount(dev)
#   fs.mkdir("/docs")
#   let f = fs.create("/docs/hello.txt")
#   f.write("hello, SprintFS")
#   f.close()
#   print(fs.read_file("/docs/hello.txt"))             # a string; fs.read_bytes(path) gives a typed.u8
#   fs.unmount()
#   sprintfs.fsck(dev)                                  # {ok: true, errors: [], ...}
#
# On-disk format (all integers little endian, block size 1024..65536, 4096 by default)
#   block 0                superblock (a backup copy sits in the last block), CRC32C protected
#   block bitmap, inode bitmap, inode table (256-byte inodes, CRC32C each), journal, then data blocks
#   inode        mode (type + permissions), flags, uid, gid, link count, size, atime / mtime / ctime (seconds + nanoseconds), 6 inline extents
#                and one extent block (255 more), an xattr block; short symbolic links live inside the inode
#   extent       {logical block, length, physical block}: files are runs of blocks, holes are sparse
#   directory    blocks of {inode, record length, name length, type, name} entries, each block ends with a CRC32C
#   journal      metadata write-ahead log (descriptor, block images, commit with CRC32C); data is written first (ordered mode), so after a crash the
#                file system is the state before or after each operation, never a mixture. mount() replays a committed transaction.
#   fsck         checks every structure and the bitmaps against what the inodes actually own, and can repair link counts, leaks and orphans.
#
# Errors are thrown with the error kind ENOENT, EEXIST, ENOTDIR, EISDIR, ENOTEMPTY, ENOSPC, EINVAL, ELOOP, ENAMETOOLONG, EBUSY, EIO or EFBIG.
import str
import typed

# ---- little-endian helpers on typed.u8 blocks --------------------------------------------------------------------------------------
func get16(b, o):
    return b[o] | (b[o + 1] << 8)

func get32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)

func get64(b, o):
    return get32(b, o) | (get32(b, o + 4) << 32)

func put16(b, o, v):
    b[o] = v & 255
    b[o + 1] = (v >> 8) & 255

func put32(b, o, v):
    b[o] = v & 255
    b[o + 1] = (v >> 8) & 255
    b[o + 2] = (v >> 16) & 255
    b[o + 3] = (v >> 24) & 255

func put64(b, o, v):
    put32(b, o, v & 0xffffffff)
    put32(b, o + 4, (v >> 32) & 0xffffffff)

func err(kind, msg):
    throw error(kind, msg)

# ---- CRC32C (Castagnoli) -------------------------------------------------------------------------------------------------------------
let CRC_T = []
func crc_init():
    for n in range(256):
        let c = n
        for k in range(8):
            if (c & 1) == 1:
                c = 0x82f63b78 ^ (c >> 1)
            else:
                c = c >> 1
        CRC_T.append(c)
crc_init()

export func crc32c(b, lo, hi):
    let c = 0xffffffff
    for i in range(lo, hi):
        c = CRC_T[(c ^ b[i]) & 255] ^ (c >> 8)
    return (~c) & 0xffffffff

# ---- block devices -------------------------------------------------------------------------------------------------------------------------
# a device has read(n) -> typed.u8 (block_size bytes), write(n, data), flush(), blocks(), block_size()
export class MemDevice:
    let bs = 4096
    let n = 0
    let data = nil
    let writes = 0
    func init(self, nblocks, block_size = 4096):
        self.bs = block_size
        self.n = nblocks
        self.data = typed.u8(nblocks * block_size)
    func blocks(self):
        return self.n
    func block_size(self):
        return self.bs
    func read(self, i):
        if i < 0 or i >= self.n:
            err("EIO", "read past the end of the device: block " .. to_string(i))
        let b = typed.u8(self.bs)
        let o = i * self.bs
        for k in range(self.bs):
            b[k] = self.data[o + k]
        return b
    func write(self, i, b):
        if i < 0 or i >= self.n:
            err("EIO", "write past the end of the device: block " .. to_string(i))
        let o = i * self.bs
        for k in range(self.bs):
            self.data[o + k] = b[k]
        self.writes += 1
    func flush(self):
        return nil
    # the whole device as a typed.u8 (for writing an image file) / a device from an image
    func to_bytes(self):
        return self.data

export func device_from_bytes(bytes, block_size = 4096):
    let n = len(bytes) // block_size
    let d = MemDevice(n, block_size)
    for i in range(n * block_size):
        d.data[i] = bytes[i]
    return d

# a device that loses power after `limit` block writes: the later writes and flushes vanish (for crash tests)
export class FaultyDevice:
    let inner = nil
    let limit = 0
    let count = 0
    func init(self, inner, limit):
        self.inner = inner
        self.limit = limit
    func blocks(self):
        return self.inner.blocks()
    func block_size(self):
        return self.inner.block_size()
    func read(self, i):
        return self.inner.read(i)
    func write(self, i, b):
        if self.count < self.limit:
            self.count += 1
            self.inner.write(i, b)
    func flush(self):
        return nil

# ---- layout ---------------------------------------------------------------------------------------------------------------------------------
const MAGIC = 0x5346544e49525053          # "SPRINTFS"
const JMAGIC = 0x4c4e524a                 # "JRNL"
const INODE_SIZE = 256
const ROOT = 1
const S_IFMT = 0xf000
const S_IFREG = 0x8000
const S_IFDIR = 0x4000
const S_IFLNK = 0xa000
const NINLINE = 6
const MAX_NAME = 255
const MAX_LINKS = 65000

# superblock fields (offsets)
const SB_MAGIC = 0
const SB_VERSION = 8
const SB_BS = 12
const SB_NBLOCKS = 16
const SB_NINODES = 24
const SB_FREE_BLOCKS = 32
const SB_FREE_INODES = 40
const SB_BMAP = 44
const SB_BMAP_N = 48
const SB_IMAP = 52
const SB_IMAP_N = 56
const SB_ITAB = 60
const SB_ITAB_N = 64
const SB_JSTART = 68
const SB_JBLOCKS = 72
const SB_DATA = 76
const SB_STATE = 80                       # 1 = cleanly unmounted, 0 = mounted
const SB_MOUNTS = 84
const SB_CTIME = 88
const SB_LABEL = 96                       # 32 bytes
const SB_UUID = 128                       # 16 bytes
const SB_CRC = 252

export class Stat:
    let ino = 0
    let mode = 0
    let kind = "file"
    let uid = 0
    let gid = 0
    let nlink = 0
    let size = 0
    let blocks = 0
    let atime = 0
    let mtime = 0
    let ctime = 0
    func init(self, ino, i, kind):
        self.ino = ino
        self.mode = i.mode & 0xfff
        self.kind = kind
        self.uid = i.uid
        self.gid = i.gid
        self.nlink = i.nlink
        self.size = i.size
        self.blocks = i.blocks
        self.atime = i.atime
        self.mtime = i.mtime
        self.ctime = i.ctime

func kind_of(mode):
    let t = mode & S_IFMT
    if t == S_IFDIR:
        return "dir"
    if t == S_IFLNK:
        return "symlink"
    return "file"

# ---- mkfs ---------------------------------------------------------------------------------------------------------------------------------------
# opts: label, uuid (16 bytes), inode_ratio (bytes of space per inode, default 16384), journal_blocks, time (seconds)
export func mkfs(dev, opts = {}):
    let bs = dev.block_size()
    let n = dev.blocks()
    if bs < 1024 or bs > 65536 or (bs & (bs - 1)) != 0:
        err("EINVAL", "the block size must be a power of two between 1024 and 65536")
    if n < 64:
        err("EINVAL", "the device is too small (at least 64 blocks)")
    let ratio = opts.inode_ratio if has(opts, "inode_ratio") else 16384
    let ninodes = n * bs // ratio
    if ninodes < 32:
        ninodes = 32
    let per_block = bs // INODE_SIZE
    let itab_n = (ninodes + per_block - 1) // per_block
    ninodes = itab_n * per_block
    let bits_per = bs * 8
    let bmap_n = (n + bits_per - 1) // bits_per
    let imap_n = (ninodes + bits_per - 1) // bits_per
    let jblocks = opts.journal_blocks if has(opts, "journal_blocks") else (n // 32)
    if jblocks < 64:
        jblocks = 64
    if jblocks > 1024:
        jblocks = 1024
    let bmap = 1
    let imap = bmap + bmap_n
    let itab = imap + imap_n
    let jstart = itab + itab_n
    let data = jstart + jblocks
    if data + 8 > n - 1:
        err("EINVAL", "the device is too small for this geometry")
    let sb = typed.u8(bs)
    put64(sb, SB_MAGIC, MAGIC)
    put32(sb, SB_VERSION, 1)
    put32(sb, SB_BS, bs)
    put64(sb, SB_NBLOCKS, n)
    put32(sb, SB_NINODES, ninodes)
    put32(sb, SB_BMAP, bmap)
    put32(sb, SB_BMAP_N, bmap_n)
    put32(sb, SB_IMAP, imap)
    put32(sb, SB_IMAP_N, imap_n)
    put32(sb, SB_ITAB, itab)
    put32(sb, SB_ITAB_N, itab_n)
    put32(sb, SB_JSTART, jstart)
    put32(sb, SB_JBLOCKS, jblocks)
    put32(sb, SB_DATA, data)
    put32(sb, SB_STATE, 1)
    let now = opts.time if has(opts, "time") else 0
    put64(sb, SB_CTIME, now)
    let label = opts.label if has(opts, "label") else ""
    for i in range(len(label)):
        if i < 31:
            sb[SB_LABEL + i] = label[i]
    let uuid = opts.uuid if has(opts, "uuid") else [0x53, 0x70, 0x72, 0x69, 0x6e, 0x74, 0x46, 0x53, 0, 0, 0, 0, 0, 0, 0, 1]
    for i in range(16):
        sb[SB_UUID + i] = uuid[i]
    # zero the metadata area
    for b in range(1, data):
        dev.write(b, typed.u8(bs))
    # block bitmap: the metadata blocks, the backup superblock and everything beyond the device are used
    for k in range(bmap_n):
        let bm = typed.u8(bs)
        for bit in range(bits_per):
            let blk = k * bits_per + bit
            if blk < data or blk == n - 1 or blk >= n:
                bm[bit >> 3] = bm[bit >> 3] | (1 << (bit & 7))
        dev.write(bmap + k, bm)
    # inode bitmap: inode 0 is invalid, inode 1 (the root) is allocated
    for k in range(imap_n):
        let im = typed.u8(bs)
        for bit in range(bits_per):
            let ino = k * bits_per + bit
            if ino == 0 or ino == ROOT or ino >= ninodes:
                im[bit >> 3] = im[bit >> 3] | (1 << (bit & 7))
        dev.write(imap + k, im)
    # the root directory: one block with a CRC
    let root_block = data
    let rb = typed.u8(bs)
    dir_init_block(rb, bs)
    dir_put_entry(rb, 0, ROOT, ".", 2, 12)
    dir_put_entry(rb, 12, ROOT, "..", 2, bs - 8 - 12)
    dir_seal(rb, bs)
    dev.write(root_block, rb)
    let bm0 = dev.read(bmap + root_block // bits_per)
    let bit = root_block % bits_per
    bm0[bit >> 3] = bm0[bit >> 3] | (1 << (bit & 7))
    dev.write(bmap + root_block // bits_per, bm0)
    let ib = typed.u8(bs)
    let root = new_inode(S_IFDIR | 0x1ed, now)
    root.nlink = 2
    root.size = bs
    root.blocks = 1
    root.ext = [[0, 1, root_block]]
    inode_encode(ib, (ROOT % per_block) * INODE_SIZE, root)
    dev.write(itab + ROOT // per_block, ib)
    put64(sb, SB_FREE_BLOCKS, n - data - 2)          # the data blocks minus the root's and the backup superblock
    put32(sb, SB_FREE_INODES, ninodes - 2)
    seal_sb(sb)
    dev.write(0, sb)
    dev.write(n - 1, sb)
    dev.flush()

func seal_sb(sb):
    put32(sb, SB_CRC, crc32c(sb, 0, SB_CRC))

# ---- inodes --------------------------------------------------------------------------------------------------------------------------------------
func new_inode(mode, now):
    return {mode: mode, flags: 0, uid: 0, gid: 0, nlink: 1, size: 0, atime: now, mtime: now, ctime: now, atime_ns: 0, mtime_ns: 0, ctime_ns: 0,
            blocks: 0, ext: [], ext_block: 0, xattr_block: 0, gen: 0, inline: nil}

# serialise the inode into `b` at `o` (the extents beyond the inline ones are written by the caller into the extent block)
func inode_encode(b, o, i):
    for k in range(INODE_SIZE):
        b[o + k] = 0
    put16(b, o, i.mode)
    put16(b, o + 2, i.flags)
    put32(b, o + 4, i.uid)
    put32(b, o + 8, i.gid)
    put32(b, o + 12, i.nlink)
    put64(b, o + 16, i.size)
    put64(b, o + 24, i.atime)
    put64(b, o + 32, i.mtime)
    put64(b, o + 40, i.ctime)
    put32(b, o + 48, i.atime_ns)
    put32(b, o + 52, i.mtime_ns)
    put32(b, o + 56, i.ctime_ns)
    put32(b, o + 60, i.blocks)
    let ne = len(i.ext)
    put16(b, o + 64, ne)
    put32(b, o + 68, i.ext_block)
    put32(b, o + 72, i.xattr_block)
    put32(b, o + 76, i.gen)
    if i.inline != nil:                       # a short symbolic link target lives in the extent area
        put16(b, o + 66, len(i.inline))
        for k in range(len(i.inline)):
            b[o + 80 + k] = i.inline[k]
    else:
        for k in range(ne):
            if k < NINLINE:
                put32(b, o + 80 + 16 * k, i.ext[k][0])
                put32(b, o + 84 + 16 * k, i.ext[k][1])
                put64(b, o + 88 + 16 * k, i.ext[k][2])
    put32(b, o + 252, crc32c(b, o, o + 252))

func inode_decode(b, o):
    if crc32c(b, o, o + 252) != get32(b, o + 252):
        err("EIO", "inode checksum mismatch")
    let i = {mode: get16(b, o), flags: get16(b, o + 2), uid: get32(b, o + 4), gid: get32(b, o + 8), nlink: get32(b, o + 12), size: get64(b, o + 16),
             atime: get64(b, o + 24), mtime: get64(b, o + 32), ctime: get64(b, o + 40), atime_ns: get32(b, o + 48), mtime_ns: get32(b, o + 52),
             ctime_ns: get32(b, o + 56), blocks: get32(b, o + 60), ext: [], ext_block: get32(b, o + 68), xattr_block: get32(b, o + 72),
             gen: get32(b, o + 76), inline: nil}
    let ne = get16(b, o + 64)
    if (i.mode & S_IFMT) == S_IFLNK and ne == 0 and get16(b, o + 66) > 0:
        let t = []
        for k in range(get16(b, o + 66)):
            t.append(b[o + 80 + k])
        i.inline = t
        return i
    for k in range(ne if ne < NINLINE else NINLINE):
        i.ext.append([get32(b, o + 80 + 16 * k), get32(b, o + 84 + 16 * k), get64(b, o + 88 + 16 * k)])
    return i

# ---- directory blocks ------------------------------------------------------------------------------------------------------------------------
# an entry: ino u32, rec_len u16, name_len u8, type u8, name; the last 8 bytes of a block hold a marker and the CRC32C of the rest
func dir_init_block(b, bs):
    for k in range(bs):
        b[k] = 0
    put32(b, bs - 8, 0x44495242)

func dir_put_entry(b, off, ino, name, ftype, rec_len):
    put32(b, off, ino)
    put16(b, off + 4, rec_len)
    b[off + 6] = len(name)
    b[off + 7] = ftype
    for k in range(len(name)):
        b[off + 8 + k] = name[k]

func dir_seal(b, bs):
    put32(b, bs - 4, crc32c(b, 0, bs - 4))

func dir_check(b, bs):
    return get32(b, bs - 8) == 0x44495242 and crc32c(b, 0, bs - 4) == get32(b, bs - 4)

func entry_size(namelen):
    return (8 + namelen + 3) & -4


# ====================================================================================================================================================
# the mounted file system
# ====================================================================================================================================================
const EXTB_MAGIC = 0x42545845             # "EXTB"
const MAX_SYMLINKS = 40

func split_path(path):
    if len(path) == 0:
        err("EINVAL", "empty path")
    let parts = []
    for p in path.split("/"):
        if len(p) > 0 and p != ".":
            if len(p) > MAX_NAME:
                err("ENAMETOOLONG", p)
            parts.append(p)
    return parts

export class File:
    let fs = nil
    let ino = 0
    let pos = 0
    let readable = true
    let writable = false
    let append = false
    let closed = false
    func init(self, fs, ino, readable, writable, append):
        self.fs = fs
        self.ino = ino
        self.readable = readable
        self.writable = writable
        self.append = append
    func size(self):
        return self.fs.iget(self.ino).size
    # up to n bytes (all the rest when n < 0) as a typed.u8
    func read(self, n = -1):
        if self.closed:
            err("EBUSY", "the file is closed")
        if not self.readable:
            err("EINVAL", "the file is not open for reading")
        let i = self.fs.iget(self.ino)
        let want = n
        if want < 0 or self.pos + want > i.size:
            want = i.size - self.pos
        if want < 0:
            want = 0
        let r = self.fs.read_data(i, self.pos, want)
        self.pos += want
        return r
    func write(self, data):
        if self.closed:
            err("EBUSY", "the file is closed")
        if not self.writable:
            err("EINVAL", "the file is not open for writing")
        if self.append:
            self.pos = self.fs.iget(self.ino).size
        let n = self.fs.write_at(self.ino, self.pos, data)
        self.pos += n
        return n
    func seek(self, off, whence = 0):
        let base = 0
        if whence == 1:
            base = self.pos
        elif whence == 2:
            base = self.size()
        let p = base + off
        if p < 0:
            err("EINVAL", "negative file position")
        self.pos = p
        return p
    func tell(self):
        return self.pos
    func truncate(self, size = nil):
        self.fs.truncate_ino(self.ino, self.pos if size == nil else size)
    func close(self):
        self.closed = true

export class Fs:
    let dev = nil
    let bs = 0
    let nblocks = 0
    let ninodes = 0
    let bmap = 0
    let bmap_n = 0
    let imap = 0
    let imap_n = 0
    let itab = 0
    let itab_n = 0
    let jstart = 0
    let jblocks = 0
    let data_start = 0
    let free_blocks = 0
    let free_inodes = 0
    let cache = nil
    let dirty = nil
    let depth = 0
    let clock = nil
    let seq = 1
    let sb_dirty = false
    let readonly = false
    let alloc_goal = 0
    let replayed = 0

    func init(self, dev, opts):
        self.dev = dev
        self.cache = {}
        self.dirty = {}
        self.clock = opts.clock if has(opts, "clock") else nil
        self.readonly = opts.readonly if has(opts, "readonly") else false
        if self.clock == nil:
            let t = [0]
            self.clock = () => t[0]
        let sb = dev.read(0)
        if get64(sb, SB_MAGIC) != MAGIC or crc32c(sb, 0, SB_CRC) != get32(sb, SB_CRC):
            sb = dev.read(dev.blocks() - 1)                      # the backup superblock
            if get64(sb, SB_MAGIC) != MAGIC or crc32c(sb, 0, SB_CRC) != get32(sb, SB_CRC):
                err("EIO", "not a SprintFS file system (bad superblock)")
        self.bs = get32(sb, SB_BS)
        if self.bs != dev.block_size():
            err("EINVAL", "the device block size differs from the file system's")
        self.nblocks = get64(sb, SB_NBLOCKS)
        self.ninodes = get32(sb, SB_NINODES)
        self.free_blocks = get64(sb, SB_FREE_BLOCKS)
        self.free_inodes = get32(sb, SB_FREE_INODES)
        self.bmap = get32(sb, SB_BMAP)
        self.bmap_n = get32(sb, SB_BMAP_N)
        self.imap = get32(sb, SB_IMAP)
        self.imap_n = get32(sb, SB_IMAP_N)
        self.itab = get32(sb, SB_ITAB)
        self.itab_n = get32(sb, SB_ITAB_N)
        self.jstart = get32(sb, SB_JSTART)
        self.jblocks = get32(sb, SB_JBLOCKS)
        self.data_start = get32(sb, SB_DATA)
        self.alloc_goal = self.data_start
        self.recover()
        # the counters may have changed by the replay: read them again
        let sb2 = dev.read(0)
        self.free_blocks = get64(sb2, SB_FREE_BLOCKS)
        self.free_inodes = get32(sb2, SB_FREE_INODES)
        if not self.readonly:
            self.begin()
            let b = self.upd(0)
            put32(b, SB_STATE, 0)
            put32(b, SB_MOUNTS, get32(b, SB_MOUNTS) + 1)
            self.sb_dirty = true
            self.end()

    # ---- the block layer: a clean cache and the dirty set of the running transaction -------------------------------------------------------
    func rblock(self, n):
        if has(self.dirty, n):
            return self.dirty[n]
        if has(self.cache, n):
            return self.cache[n]
        let b = self.dev.read(n)
        if len(self.cache) > 4096:
            self.cache = {}
        self.cache[n] = b
        return b
    # a writable copy of block n, part of the running transaction
    func upd(self, n):
        if self.readonly:
            err("EINVAL", "the file system is mounted read-only")
        if has(self.dirty, n):
            return self.dirty[n]
        let src = self.rblock(n)
        let b = typed.u8(self.bs)
        for k in range(self.bs):
            b[k] = src[k]
        self.dirty[n] = b
        return b
    func fresh(self, n):
        # a block that is overwritten completely (a new directory or extent block)
        if self.readonly:
            err("EINVAL", "the file system is mounted read-only")
        let b = typed.u8(self.bs)
        self.dirty[n] = b
        return b
    func begin(self):
        self.depth += 1
    func end(self):
        self.depth -= 1
        if self.depth == 0:
            self.commit()
    func abort(self):
        # an operation failed half-way: forget its metadata changes (the data blocks it wrote are unreferenced)
        self.depth = 0
        self.dirty = {}
        self.cache = {}
        self.sb_dirty = false
        let sb = self.dev.read(0)
        self.free_blocks = get64(sb, SB_FREE_BLOCKS)
        self.free_inodes = get32(sb, SB_FREE_INODES)

    # ---- the journal -------------------------------------------------------------------------------------------------------------------------
    func commit(self):
        if self.sb_dirty:
            let b = self.upd(0)
            put64(b, SB_FREE_BLOCKS, self.free_blocks)
            put32(b, SB_FREE_INODES, self.free_inodes)
            seal_sb(b)
            self.sb_dirty = false
        if len(self.dirty) == 0:
            return nil
        let keys = []
        for k, v in self.dirty:
            keys.append(k)
        keys.sort((a, b) => a < b)
        let cap = self.jblocks - 3
        let per = (self.bs - 16) // 8
        if per < cap:
            cap = per
        let i = 0
        while i < len(keys):
            let hi = i + cap
            if hi > len(keys):
                hi = len(keys)
            let chunk = []
            for k in range(i, hi):
                chunk.append(keys[k])
            self.journal_write(chunk)
            for k in chunk:
                self.dev.write(k, self.dirty[k])
            self.dev.flush()
            self.journal_clear()
            i = hi
        for k in keys:
            self.cache[k] = self.dirty[k]
        self.dirty = {}
    func journal_crc(self, desc, chunk):
        let c = crc32c(desc, 0, 16 + 8 * len(chunk))
        let blob = typed.u8(self.bs)
        let all = c
        for n in chunk:
            all = (all * 31 + crc32c(self.dirty[n], 0, self.bs)) & 0xffffffff
        return all
    func journal_write(self, chunk):
        let desc = typed.u8(self.bs)
        put32(desc, 0, JMAGIC)
        put32(desc, 4, self.seq)
        put32(desc, 8, len(chunk))
        for k in range(len(chunk)):
            put64(desc, 16 + 8 * k, chunk[k])
        let crc = self.journal_crc(desc, chunk)
        put32(desc, 12, crc)
        self.dev.write(self.jstart + 1, desc)
        for k in range(len(chunk)):
            self.dev.write(self.jstart + 2 + k, self.dirty[chunk[k]])
        self.dev.flush()
        let commit = typed.u8(self.bs)
        put32(commit, 0, JMAGIC ^ 0xffffffff)
        put32(commit, 4, self.seq)
        put32(commit, 8, len(chunk))
        put32(commit, 12, crc)
        self.dev.write(self.jstart + 2 + len(chunk), commit)
        self.dev.flush()
        self.seq += 1
    func journal_clear(self):
        self.dev.write(self.jstart + 1, typed.u8(self.bs))
        self.dev.flush()
    # replay a transaction whose commit block reached the disk
    func recover(self):
        let desc = self.dev.read(self.jstart + 1)
        if get32(desc, 0) != JMAGIC:
            return nil
        let count = get32(desc, 8)
        let seq = get32(desc, 4)
        if count == 0 or count > (self.bs - 16) // 8 or count > self.jblocks - 3:
            return nil
        let commit = self.dev.read(self.jstart + 2 + count)
        if get32(commit, 0) != (JMAGIC ^ 0xffffffff) or get32(commit, 4) != seq or get32(commit, 8) != count:
            self.journal_clear_raw()
            return nil
        let chunk = []
        let images = []
        let stored = get32(desc, 12)
        put32(desc, 12, 0)                       # the checksum covers the descriptor with its own field zeroed
        let all = crc32c(desc, 0, 16 + 8 * count)
        put32(desc, 12, stored)
        for k in range(count):
            chunk.append(get64(desc, 16 + 8 * k))
            let img = self.dev.read(self.jstart + 2 + k)
            images.append(img)
            all = (all * 31 + crc32c(img, 0, self.bs)) & 0xffffffff
        if all != get32(commit, 12) or all != get32(desc, 12):
            self.journal_clear_raw()
            return nil
        if not self.readonly:
            for k in range(count):
                self.dev.write(chunk[k], images[k])
            self.dev.flush()
            self.journal_clear_raw()
        self.replayed += 1
        self.seq = seq + 1
    func journal_clear_raw(self):
        if not self.readonly:
            self.dev.write(self.jstart + 1, typed.u8(self.bs))
            self.dev.flush()

    # ---- allocation ---------------------------------------------------------------------------------------------------------------------------
    func block_used(self, n):
        let bits = self.bs * 8
        let b = self.rblock(self.bmap + n // bits)
        let bit = n % bits
        return ((b[bit >> 3] >> (bit & 7)) & 1) == 1
    func set_block(self, n, used):
        let bits = self.bs * 8
        let b = self.upd(self.bmap + n // bits)
        let bit = n % bits
        if used:
            b[bit >> 3] = b[bit >> 3] | (1 << (bit & 7))
        else:
            b[bit >> 3] = b[bit >> 3] & ~(1 << (bit & 7)) & 255
    # up to `want` blocks as a list of [physical, length] runs, preferring one run starting at `goal`
    func alloc_blocks(self, want, goal):
        if want > self.free_blocks:
            err("ENOSPC", "no space left on the file system")
        let runs = []
        let need = want
        let n = goal
        if n < self.data_start or n >= self.nblocks:
            n = self.data_start
        let scanned = 0
        let total = self.nblocks
        while need > 0 and scanned < total:
            if n >= self.nblocks:
                n = self.data_start
            # skip used blocks quickly (a byte of eight used bits at a time)
            if self.block_used(n):
                n += 1
                scanned += 1
                continue
            let start = n
            while n < self.nblocks and need > 0 and not self.block_used(n):
                n += 1
                need -= 1
            let len_ = n - start
            for k in range(start, n):
                self.set_block(k, true)
            runs.append([start, len_])
            scanned += len_
        if need > 0:
            for r in runs:
                for k in range(r[0], r[0] + r[1]):
                    self.set_block(k, false)
            err("ENOSPC", "no space left on the file system")
        self.free_blocks -= want
        self.sb_dirty = true
        self.alloc_goal = n
        return runs
    func free_run(self, phys, len_):
        for k in range(phys, phys + len_):
            if not self.block_used(k):
                err("EIO", "freeing a block that is not allocated: " .. to_string(k))
            self.set_block(k, false)
        self.free_blocks += len_
        self.sb_dirty = true
    func alloc_inode(self):
        let bits = self.bs * 8
        for k in range(self.imap_n):
            let b = self.rblock(self.imap + k)
            for byte in range(self.bs):
                if b[byte] != 255:
                    for bit in range(8):
                        if ((b[byte] >> bit) & 1) == 0:
                            let ino = k * bits + byte * 8 + bit
                            if ino >= self.ninodes:
                                err("ENOSPC", "no free inodes")
                            let w = self.upd(self.imap + k)
                            w[byte] = w[byte] | (1 << bit)
                            self.free_inodes -= 1
                            self.sb_dirty = true
                            return ino
        err("ENOSPC", "no free inodes")
    func free_inode(self, ino):
        let bits = self.bs * 8
        let w = self.upd(self.imap + ino // bits)
        let bit = ino % bits
        w[bit >> 3] = w[bit >> 3] & ~(1 << (bit & 7)) & 255
        self.free_inodes += 1
        self.sb_dirty = true
        # clear the slot so a stale inode cannot be mistaken for a live one
        let per = self.bs // INODE_SIZE
        let t = self.upd(self.itab + ino // per)
        let o = (ino % per) * INODE_SIZE
        for k in range(INODE_SIZE):
            t[o + k] = 0
    func inode_used(self, ino):
        let bits = self.bs * 8
        let b = self.rblock(self.imap + ino // bits)
        let bit = ino % bits
        return ((b[bit >> 3] >> (bit & 7)) & 1) == 1

    # ---- inodes and their extents ---------------------------------------------------------------------------------------------------------
    func iget(self, ino):
        if ino <= 0 or ino >= self.ninodes or not self.inode_used(ino):
            err("EIO", "inode " .. to_string(ino) .. " is not allocated")
        let per = self.bs // INODE_SIZE
        let b = self.rblock(self.itab + ino // per)
        let i = inode_decode(b, (ino % per) * INODE_SIZE)
        if i.ext_block != 0:
            let eb = self.rblock(i.ext_block)
            if get32(eb, 0) != EXTB_MAGIC or crc32c(eb, 0, self.bs - 4) != get32(eb, self.bs - 4):
                err("EIO", "extent block checksum mismatch")
            let cnt = get32(eb, 4)
            for k in range(cnt):
                i.ext.append([get32(eb, 16 + 16 * k), get32(eb, 20 + 16 * k), get64(eb, 24 + 16 * k)])
        return i
    func iput(self, ino, i):
        let per = self.bs // INODE_SIZE
        let maxext = (self.bs - 20) // 16
        if len(i.ext) > NINLINE + maxext:
            err("ENOSPC", "the file is too fragmented")
        if len(i.ext) > NINLINE:
            if i.ext_block == 0:
                let r = self.alloc_blocks(1, self.alloc_goal)
                i.ext_block = r[0][0]
                i.blocks += 1
            let eb = self.fresh(i.ext_block)
            put32(eb, 0, EXTB_MAGIC)
            put32(eb, 4, len(i.ext) - NINLINE)
            for k in range(NINLINE, len(i.ext)):
                put32(eb, 16 + 16 * (k - NINLINE), i.ext[k][0])
                put32(eb, 20 + 16 * (k - NINLINE), i.ext[k][1])
                put64(eb, 24 + 16 * (k - NINLINE), i.ext[k][2])
            put32(eb, self.bs - 4, crc32c(eb, 0, self.bs - 4))
        elif i.ext_block != 0:
            self.free_run(i.ext_block, 1)
            i.ext_block = 0
            i.blocks -= 1
        let t = self.upd(self.itab + ino // per)
        inode_encode(t, (ino % per) * INODE_SIZE, i)
    func now(self):
        return self.clock()
    # the physical block of logical block l, or -1 for a hole
    func bmap_of(self, i, l):
        for e in i.ext:
            if l >= e[0] and l < e[0] + e[1]:
                return e[2] + (l - e[0])
            if e[0] > l:
                break
        return -1
    # add [l, len) -> phys to the (sorted) extent list, merging neighbours
    func ext_add(self, i, l, len_, phys):
        let pos = 0
        while pos < len(i.ext) and i.ext[pos][0] < l:
            pos += 1
        i.ext.insert(pos, [l, len_, phys])
        if pos + 1 < len(i.ext):
            let a = i.ext[pos]
            let b = i.ext[pos + 1]
            if a[0] + a[1] == b[0] and a[2] + a[1] == b[2]:
                a[1] += b[1]
                i.ext.remove_at(pos + 1)
        if pos > 0:
            let a = i.ext[pos - 1]
            let b = i.ext[pos]
            if a[0] + a[1] == b[0] and a[2] + a[1] == b[2]:
                a[1] += b[1]
                i.ext.remove_at(pos)
    # make sure the logical blocks [first, last) are backed by blocks
    func ensure(self, i, first, last):
        let l = first
        while l < last:
            if self.bmap_of(i, l) >= 0:
                l += 1
                continue
            let h = l
            while h < last and self.bmap_of(i, h) < 0:
                h += 1
            # the goal: right after the block before the hole
            let goal = self.alloc_goal
            let before = self.bmap_of(i, l - 1) if l > 0 else -1
            if before >= 0:
                goal = before + 1
            let runs = self.alloc_blocks(h - l, goal)
            let at = l
            for r in runs:
                self.ext_add(i, at, r[1], r[0])
                at += r[1]
            i.blocks += h - l
            l = h
    # drop everything from logical block `keep` on
    func ext_truncate(self, i, keep):
        let out = []
        for e in i.ext:
            if e[0] >= keep:
                self.free_run(e[2], e[1])
                i.blocks -= e[1]
            elif e[0] + e[1] > keep:
                let n = keep - e[0]
                self.free_run(e[2] + n, e[1] - n)
                i.blocks -= e[1] - n
                out.append([e[0], n, e[2]])
            else:
                out.append(e)
        i.ext = out

    # ---- file data --------------------------------------------------------------------------------------------------------------------------------
    func read_data(self, i, off, n):
        let out = typed.u8(n)
        if i.inline != nil:
            for k in range(n):
                out[k] = i.inline[off + k]
            return out
        let bs = self.bs
        let done = 0
        while done < n:
            let pos = off + done
            let l = pos // bs
            let within = pos % bs
            let take = bs - within
            if take > n - done:
                take = n - done
            let phys = self.bmap_of(i, l)
            if phys >= 0:
                let b = self.rblock(phys) if has(self.dirty, phys) else self.dev.read(phys)
                for k in range(take):
                    out[done + k] = b[within + k]
            done += take
        return out
    # write `data` (a string, a typed.u8 or an array of bytes) at `off`; the data blocks go to the disk now (ordered mode), the metadata in the transaction
    func write_at(self, ino, off, data):
        let n = len(data)
        if n == 0:
            return 0
        self.begin()
        try:
            let i = self.iget(ino)
            if (i.mode & S_IFMT) == S_IFDIR:
                err("EISDIR", "is a directory")
            let bs = self.bs
            let end = off + n
            if end > 0xffffffff * bs:
                err("EFBIG", "file too large")
            self.ensure(i, off // bs, (end + bs - 1) // bs)
            let done = 0
            while done < n:
                let pos = off + done
                let l = pos // bs
                let within = pos % bs
                let take = bs - within
                if take > n - done:
                    take = n - done
                let phys = self.bmap_of(i, l)
                if has(self.dirty, phys):
                    let w = self.dirty[phys]
                    for k in range(take):
                        w[within + k] = data[done + k]
                else:
                    let b = nil
                    if take == bs:
                        b = typed.u8(bs)
                    else:
                        b = self.dev.read(phys)
                    for k in range(take):
                        b[within + k] = data[done + k]
                    self.dev.write(phys, b)
                    self.cache[phys] = nil
                done += take
            if end > i.size:
                i.size = end
            i.mtime = self.now()
            i.ctime = i.mtime
            self.iput(ino, i)
        catch e:
            self.abort()
            throw e
        self.end()
        return n
    func truncate_ino(self, ino, size):
        self.begin()
        try:
            let i = self.iget(ino)
            if (i.mode & S_IFMT) == S_IFDIR:
                err("EISDIR", "is a directory")
            let bs = self.bs
            if size < i.size:
                self.ext_truncate(i, (size + bs - 1) // bs)
                # zero the tail of the last kept block
                if size % bs != 0:
                    let phys = self.bmap_of(i, size // bs)
                    if phys >= 0:
                        let b = self.upd(phys)                  # a journaled block: the new size and the zeroed tail commit together
                        for k in range(size % bs, bs):
                            b[k] = 0
            i.size = size
            i.mtime = self.now()
            i.ctime = i.mtime
            self.iput(ino, i)
        catch e:
            self.abort()
            throw e
        self.end()

    # ---- directories ----------------------------------------------------------------------------------------------------------------------------
    # the entries of a directory as [{name, ino, type, blk, off}]
    func dir_entries(self, dino):
        let d = self.iget(dino)
        let out = []
        let nb = d.size // self.bs
        for l in range(nb):
            let phys = self.bmap_of(d, l)
            if phys < 0:
                err("EIO", "directory with a hole")
            let b = self.rblock(phys)
            if not dir_check(b, self.bs):
                err("EIO", "directory block checksum mismatch")
            let off = 0
            while off < self.bs - 8:
                let ino = get32(b, off)
                let rec = get16(b, off + 4)
                if rec < 8 or (rec & 3) != 0 or off + rec > self.bs - 8:
                    err("EIO", "corrupt directory entry")
                if ino != 0:
                    let nl = b[off + 6]
                    let name = ""
                    let bytes = []
                    for k in range(nl):
                        bytes.append(b[off + 8 + k])
                    out.append({name: bytes_to_str(bytes), ino: ino, type: b[off + 7], blk: phys, off: off})
                off += rec
        return out
    func dir_lookup(self, dino, name):
        for e in self.dir_entries(dino):
            if e.name == name:
                return e
        return nil
    func dir_add(self, dino, name, ino, ftype):
        let d = self.iget(dino)
        let need = entry_size(len(name))
        let nb = d.size // self.bs
        for l in range(nb):
            let phys = self.bmap_of(d, l)
            let b = self.rblock(phys)
            let off = 0
            while off < self.bs - 8:
                let eino = get32(b, off)
                let rec = get16(b, off + 4)
                let used = 0 if eino == 0 else entry_size(b[off + 6])
                if rec - used >= need:
                    let w = self.upd(phys)
                    if eino == 0:
                        dir_put_entry(w, off, ino, name, ftype, rec)
                    else:
                        put16(w, off + 4, used)
                        dir_put_entry(w, off + used, ino, name, ftype, rec - used)
                    dir_seal(w, self.bs)
                    return nil
                off += rec
        # no room: append a block
        let l = nb
        self.ensure(d, l, l + 1)
        let phys = self.bmap_of(d, l)
        let w = self.fresh(phys)
        dir_init_block(w, self.bs)
        dir_put_entry(w, 0, ino, name, ftype, self.bs - 8)
        dir_seal(w, self.bs)
        d.size += self.bs
        self.iput(dino, d)
    func dir_remove(self, dino, name):
        let d = self.iget(dino)
        for l in range(d.size // self.bs):
            let phys = self.bmap_of(d, l)
            let b = self.rblock(phys)
            let off = 0
            let prev = -1
            while off < self.bs - 8:
                let ino = get32(b, off)
                let rec = get16(b, off + 4)
                if ino != 0 and b[off + 6] == len(name):
                    let same = true
                    for k in range(len(name)):
                        if b[off + 8 + k] != name[k]:
                            same = false
                    if same:
                        let w = self.upd(phys)
                        if prev >= 0:
                            put16(w, prev + 4, get16(w, prev + 4) + rec)
                        else:
                            put32(w, off, 0)
                        dir_seal(w, self.bs)
                        return nil
                prev = off
                off += rec
        err("ENOENT", name)
    func dir_set_ino(self, dino, name, ino, ftype):
        let e = self.dir_lookup(dino, name)
        let w = self.upd(e.blk)
        put32(w, e.off, ino)
        w[e.off + 7] = ftype
        dir_seal(w, self.bs)

    # ---- paths ------------------------------------------------------------------------------------------------------------------------------------
    func read_link_target(self, i):
        if i.inline != nil:
            return bytes_to_str(i.inline)
        let b = self.read_data(i, 0, i.size)
        let bytes = []
        for x in b:
            bytes.append(x)
        return bytes_to_str(bytes)
    # the inode a path names (the last component's symlink is followed when `follow`)
    func resolve(self, path, follow = true):
        let todo = split_path(path)
        todo.reverse()
        let cur = ROOT
        let links = 0
        while len(todo) > 0:
            let name = todo.pop()
            let i = self.iget(cur)
            if (i.mode & S_IFMT) != S_IFDIR:
                err("ENOTDIR", path)
            let e = self.dir_lookup(cur, name)
            if e == nil:
                err("ENOENT", path)
            let ch = self.iget(e.ino)
            if (ch.mode & S_IFMT) == S_IFLNK and (follow or len(todo) > 0):
                links += 1
                if links > MAX_SYMLINKS:
                    err("ELOOP", path)
                let target = self.read_link_target(ch)
                if target.starts_with("/"):
                    cur = ROOT
                let parts = split_path(target) if len(split_path_safe(target)) > 0 else []
                parts.reverse()
                for p in parts:
                    todo.append(p)
                continue
            cur = e.ino
        return cur
    # (directory inode, last name) for a path whose last component may not exist
    func parent_of(self, path):
        let parts = split_path(path)
        if len(parts) == 0:
            err("EINVAL", "the root has no parent")
        let name = parts.pop()
        let dino = ROOT
        if len(parts) > 0:
            dino = self.resolve("/" .. parts.join("/"), true)
        if (self.iget(dino).mode & S_IFMT) != S_IFDIR:
            err("ENOTDIR", path)
        return [dino, name]

    # ---- public operations ----------------------------------------------------------------------------------------------------------------------
    func exists(self, path):
        try:
            self.resolve(path, true)
            return true
        catch e:
            if e.kind == "ENOENT" or e.kind == "ENOTDIR":
                return false
            throw e
    func stat(self, path):
        let ino = self.resolve(path, true)
        let i = self.iget(ino)
        return Stat(ino, i, kind_of(i.mode))
    func lstat(self, path):
        let ino = self.resolve(path, false)
        let i = self.iget(ino)
        return Stat(ino, i, kind_of(i.mode))
    func is_dir(self, path):
        return self.exists(path) and self.stat(path).kind == "dir"
    func is_file(self, path):
        return self.exists(path) and self.stat(path).kind == "file"
    func listdir(self, path = "/"):
        let ino = self.resolve(path, true)
        if (self.iget(ino).mode & S_IFMT) != S_IFDIR:
            err("ENOTDIR", path)
        let names = []
        for e in self.dir_entries(ino):
            if e.name != "." and e.name != "..":
                names.append(e.name)
        names.sort((a, b) => a < b)
        return names
    func statfs(self):
        return {block_size: self.bs, blocks: self.nblocks, free_blocks: self.free_blocks, inodes: self.ninodes, free_inodes: self.free_inodes,
                data_start: self.data_start, journal_blocks: self.jblocks, replayed: self.replayed}

    func make_node(self, path, mode, kind_bits, init):
        self.begin()
        try:
            let po = self.parent_of(path)
            if self.dir_lookup(po[0], po[1]) != nil:
                err("EEXIST", path)
            let ino = self.alloc_inode()
            let i = new_inode(kind_bits | (mode & 0xfff), self.now())
            init(i)
            self.iput(ino, i)
            self.dir_add(po[0], po[1], ino, 2 if kind_bits == S_IFDIR else (7 if kind_bits == S_IFLNK else 1))
            if kind_bits == S_IFDIR:
                let p = self.iget(po[0])
                if p.nlink >= MAX_LINKS:
                    err("EINVAL", "too many links")
                p.nlink += 1
                p.mtime = self.now()
                p.ctime = p.mtime
                self.iput(po[0], p)
            else:
                let p = self.iget(po[0])
                p.mtime = self.now()
                p.ctime = p.mtime
                self.iput(po[0], p)
            self.end()
            return ino
        catch e:
            self.abort()
            throw e
    func mkdir(self, path, mode = 0x1ed):
        let me = self
        let ino = 0
        # the new directory gets one block holding "." and ".."
        self.begin()
        try:
            let po = self.parent_of(path)
            if self.dir_lookup(po[0], po[1]) != nil:
                err("EEXIST", path)
            ino = self.alloc_inode()
            let i = new_inode(S_IFDIR | (mode & 0xfff), self.now())
            i.nlink = 2
            self.ensure(i, 0, 1)
            let phys = self.bmap_of(i, 0)
            let b = self.fresh(phys)
            dir_init_block(b, self.bs)
            dir_put_entry(b, 0, ino, ".", 2, 12)
            dir_put_entry(b, 12, po[0], "..", 2, self.bs - 8 - 12)
            dir_seal(b, self.bs)
            i.size = self.bs
            self.iput(ino, i)
            self.dir_add(po[0], po[1], ino, 2)
            let p = self.iget(po[0])
            if p.nlink >= MAX_LINKS:
                err("EINVAL", "too many links")
            p.nlink += 1
            p.mtime = self.now()
            p.ctime = p.mtime
            self.iput(po[0], p)
        catch e:
            self.abort()
            throw e
        self.end()
    func makedirs(self, path):
        let cur = ""
        for p in split_path(path):
            cur = cur .. "/" .. p
            if not self.exists(cur):
                self.mkdir(cur)
    # open a file: mode "r" (read), "r+" (read and write), "w" (create or truncate), "w+" , "a" (append, creating), "x" (create, must not exist)
    func open(self, path, mode = "r"):
        let plus = mode.contains("+")
        let kind = mode.slice(0, 1)
        if kind == "r":
            let ino = self.resolve(path, true)
            if (self.iget(ino).mode & S_IFMT) == S_IFDIR:
                err("EISDIR", path)
            return File(self, ino, true, plus, false)
        let ino = 0
        if self.exists(path):
            if kind == "x":
                err("EEXIST", path)
            ino = self.resolve(path, true)
            if (self.iget(ino).mode & S_IFMT) == S_IFDIR:
                err("EISDIR", path)
            if kind == "w":
                self.truncate_ino(ino, 0)
        else:
            ino = self.make_node(path, 0x1a4, S_IFREG, i => nil)
        return File(self, ino, plus, true, kind == "a")
    func create(self, path, mode = 0x1a4):
        if self.exists(path):
            err("EEXIST", path)
        let ino = self.make_node(path, mode, S_IFREG, i => nil)
        return File(self, ino, true, true, false)
    func read_bytes(self, path):
        let ino = self.resolve(path, true)
        let i = self.iget(ino)
        if (i.mode & S_IFMT) == S_IFDIR:
            err("EISDIR", path)
        return self.read_data(i, 0, i.size)
    func read_file(self, path):
        let b = self.read_bytes(path)
        let bytes = []
        for x in b:
            bytes.append(x)
        return bytes_to_str(bytes)
    func write_file(self, path, data):
        let f = self.open(path, "w")
        f.write(data)
        f.close()
    func append_file(self, path, data):
        let f = self.open(path, "a")
        f.write(data)
        f.close()
    func truncate(self, path, size):
        self.truncate_ino(self.resolve(path, true), size)
    func remove_inode_data(self, ino, i):
        # free what the inode owns, then the inode itself
        for e in i.ext:
            self.free_run(e[2], e[1])
        if i.ext_block != 0:
            self.free_run(i.ext_block, 1)
        if i.xattr_block != 0:
            self.free_run(i.xattr_block, 1)
        self.free_inode(ino)
    func unlink(self, path):
        self.begin()
        try:
            let po = self.parent_of(path)
            let e = self.dir_lookup(po[0], po[1])
            if e == nil:
                err("ENOENT", path)
            let i = self.iget(e.ino)
            if (i.mode & S_IFMT) == S_IFDIR:
                err("EISDIR", path)
            self.dir_remove(po[0], po[1])
            i.nlink -= 1
            i.ctime = self.now()
            if i.nlink == 0:
                self.remove_inode_data(e.ino, i)
            else:
                self.iput(e.ino, i)
            let p = self.iget(po[0])
            p.mtime = self.now()
            p.ctime = p.mtime
            self.iput(po[0], p)
        catch e:
            self.abort()
            throw e
        self.end()
    func rmdir(self, path):
        self.begin()
        try:
            let po = self.parent_of(path)
            let e = self.dir_lookup(po[0], po[1])
            if e == nil:
                err("ENOENT", path)
            let i = self.iget(e.ino)
            if (i.mode & S_IFMT) != S_IFDIR:
                err("ENOTDIR", path)
            for x in self.dir_entries(e.ino):
                if x.name != "." and x.name != "..":
                    err("ENOTEMPTY", path)
            self.dir_remove(po[0], po[1])
            self.remove_inode_data(e.ino, i)
            let p = self.iget(po[0])
            p.nlink -= 1
            p.mtime = self.now()
            p.ctime = p.mtime
            self.iput(po[0], p)
        catch e:
            self.abort()
            throw e
        self.end()
    func link(self, existing, path):
        self.begin()
        try:
            let ino = self.resolve(existing, false)
            let i = self.iget(ino)
            if (i.mode & S_IFMT) == S_IFDIR:
                err("EISDIR", "hard links to directories are not allowed")
            if i.nlink >= MAX_LINKS:
                err("EINVAL", "too many links")
            let po = self.parent_of(path)
            if self.dir_lookup(po[0], po[1]) != nil:
                err("EEXIST", path)
            self.dir_add(po[0], po[1], ino, 7 if (i.mode & S_IFMT) == S_IFLNK else 1)
            i.nlink += 1
            i.ctime = self.now()
            self.iput(ino, i)
        catch e:
            self.abort()
            throw e
        self.end()
    func symlink(self, target, path):
        if len(target) == 0 or len(target) > 4096:
            err("EINVAL", "bad symlink target")
        let me = self
        self.begin()
        try:
            let ino = self.make_node(path, 0x1ff, S_IFLNK, i => nil)
            let i = self.iget(ino)
            if len(target) <= 96:
                let bytes = []
                for k in range(len(target)):
                    bytes.append(target[k])
                i.inline = bytes
                i.size = len(target)
                self.iput(ino, i)
            else:
                self.iput(ino, i)
                self.write_at(ino, 0, target)
        catch e:
            self.abort()
            throw e
        self.end()
    func readlink(self, path):
        let ino = self.resolve(path, false)
        let i = self.iget(ino)
        if (i.mode & S_IFMT) != S_IFLNK:
            err("EINVAL", "not a symbolic link")
        return self.read_link_target(i)
    func rename(self, old, new):
        self.begin()
        try:
            let a = self.parent_of(old)
            let src = self.dir_lookup(a[0], a[1])
            if src == nil:
                err("ENOENT", old)
            let si = self.iget(src.ino)
            let is_dir = (si.mode & S_IFMT) == S_IFDIR
            let b = self.parent_of(new)
            if a[0] == b[0] and a[1] == b[1]:
                self.end()
                return nil
            if is_dir:
                # a directory cannot move into itself: walk up from the new parent
                let cur = b[0]
                while true:
                    if cur == src.ino:
                        err("EINVAL", "cannot move a directory into itself")
                    if cur == ROOT:
                        break
                    cur = self.dir_lookup(cur, "..").ino
            let dst = self.dir_lookup(b[0], b[1])
            if dst != nil:
                let di = self.iget(dst.ino)
                let d_dir = (di.mode & S_IFMT) == S_IFDIR
                if dst.ino == src.ino:
                    self.end()
                    return nil
                if is_dir and not d_dir:
                    err("ENOTDIR", new)
                if not is_dir and d_dir:
                    err("EISDIR", new)
                if d_dir:
                    for x in self.dir_entries(dst.ino):
                        if x.name != "." and x.name != "..":
                            err("ENOTEMPTY", new)
                self.dir_remove(b[0], b[1])
                if d_dir:
                    self.remove_inode_data(dst.ino, di)
                    let np = self.iget(b[0])
                    np.nlink -= 1
                    self.iput(b[0], np)
                else:
                    di.nlink -= 1
                    if di.nlink == 0:
                        self.remove_inode_data(dst.ino, di)
                    else:
                        self.iput(dst.ino, di)
            self.dir_add(b[0], b[1], src.ino, src.type)
            self.dir_remove(a[0], a[1])
            if is_dir and a[0] != b[0]:
                self.dir_set_ino(src.ino, "..", b[0], 2)
                let op = self.iget(a[0])
                op.nlink -= 1
                self.iput(a[0], op)
                let np = self.iget(b[0])
                np.nlink += 1
                self.iput(b[0], np)
            si = self.iget(src.ino)
            si.ctime = self.now()
            self.iput(src.ino, si)
        catch e:
            self.abort()
            throw e
        self.end()
    func chmod(self, path, mode):
        self.begin()
        let ino = self.resolve(path, true)
        let i = self.iget(ino)
        i.mode = (i.mode & S_IFMT) | (mode & 0xfff)
        i.ctime = self.now()
        self.iput(ino, i)
        self.end()
    func chown(self, path, uid, gid):
        self.begin()
        let ino = self.resolve(path, true)
        let i = self.iget(ino)
        i.uid = uid
        i.gid = gid
        i.ctime = self.now()
        self.iput(ino, i)
        self.end()
    func utime(self, path, atime, mtime):
        self.begin()
        let ino = self.resolve(path, true)
        let i = self.iget(ino)
        i.atime = atime
        i.mtime = mtime
        i.ctime = self.now()
        self.iput(ino, i)
        self.end()

    # ---- extended attributes: one block per inode, entries {name length u8, value length u16, name, value} ----------------------------------------
    func xattrs(self, i):
        let out = []
        if i.xattr_block == 0:
            return out
        let b = self.rblock(i.xattr_block)
        if get32(b, 0) != 0x52545841 or crc32c(b, 0, self.bs - 4) != get32(b, self.bs - 4):
            err("EIO", "xattr block checksum mismatch")
        let o = 8
        let n = get32(b, 4)
        for k in range(n):
            let nl = b[o]
            let vl = get16(b, o + 1)
            let name = []
            let val = []
            for x in range(nl):
                name.append(b[o + 3 + x])
            for x in range(vl):
                val.append(b[o + 3 + nl + x])
            out.append([bytes_to_str(name), val])
            o += 3 + nl + vl
        return out
    func store_xattrs(self, ino, i, list):
        if len(list) == 0:
            if i.xattr_block != 0:
                self.free_run(i.xattr_block, 1)
                i.xattr_block = 0
                i.blocks -= 1
            self.iput(ino, i)
            return nil
        if i.xattr_block == 0:
            let r = self.alloc_blocks(1, self.alloc_goal)
            i.xattr_block = r[0][0]
            i.blocks += 1
        let b = self.fresh(i.xattr_block)
        put32(b, 0, 0x52545841)
        put32(b, 4, len(list))
        let o = 8
        for x in list:
            if o + 3 + len(x[0]) + len(x[1]) > self.bs - 4:
                err("ENOSPC", "the attributes do not fit in one block")
            b[o] = len(x[0])
            put16(b, o + 1, len(x[1]))
            for k in range(len(x[0])):
                b[o + 3 + k] = x[0][k]
            for k in range(len(x[1])):
                b[o + 3 + len(x[0]) + k] = x[1][k]
            o += 3 + len(x[0]) + len(x[1])
        put32(b, self.bs - 4, crc32c(b, 0, self.bs - 4))
        self.iput(ino, i)
    func setxattr(self, path, name, value):
        if len(name) == 0 or len(name) > 255 or len(value) > 65535:
            err("EINVAL", "bad attribute")
        self.begin()
        try:
            let ino = self.resolve(path, true)
            let i = self.iget(ino)
            let list = []
            let found = false
            for x in self.xattrs(i):
                if x[0] == name:
                    list.append([name, value_bytes(value)])
                    found = true
                else:
                    list.append(x)
            if not found:
                list.append([name, value_bytes(value)])
            self.store_xattrs(ino, i, list)
        catch e:
            self.abort()
            throw e
        self.end()
    func getxattr(self, path, name):
        for x in self.xattrs(self.iget(self.resolve(path, true))):
            if x[0] == name:
                let t = typed.u8(len(x[1]))
                for k in range(len(x[1])):
                    t[k] = x[1][k]
                return t
        err("ENOENT", "no such attribute: " .. name)
    func listxattr(self, path):
        let names = []
        for x in self.xattrs(self.iget(self.resolve(path, true))):
            names.append(x[0])
        return names
    func removexattr(self, path, name):
        self.begin()
        try:
            let ino = self.resolve(path, true)
            let i = self.iget(ino)
            let list = []
            let found = false
            for x in self.xattrs(i):
                if x[0] == name:
                    found = true
                else:
                    list.append(x)
            if not found:
                err("ENOENT", "no such attribute: " .. name)
            self.store_xattrs(ino, i, list)
        catch e:
            self.abort()
            throw e
        self.end()

    func sync(self):
        self.commit()
        self.dev.flush()
    func unmount(self):
        if self.readonly:
            return nil
        self.begin()
        let b = self.upd(0)
        put32(b, SB_STATE, 1)
        put64(b, SB_FREE_BLOCKS, self.free_blocks)
        put32(b, SB_FREE_INODES, self.free_inodes)
        seal_sb(b)
        self.sb_dirty = false
        self.end()
        # the backup superblock follows the primary
        self.dev.write(self.nblocks - 1, self.rblock(0))
        self.dev.flush()

func value_bytes(v):
    let out = []
    for k in range(len(v)):
        out.append(v[k])
    return out

# a string from UTF-8 bytes (an array of ints)
func bytes_to_str(bytes):
    if len(bytes) == 0:
        return ""
    return str.from_bytes(bytes)

func split_path_safe(p):
    let out = []
    for x in p.split("/"):
        if len(x) > 0 and x != ".":
            out.append(x)
    return out

export func mount(dev, opts = {}):
    return Fs(dev, opts)

# ====================================================================================================================================================
# fsck: check every structure, and with repair = true fix link counts, leaked and wrongly-free blocks, orphaned inodes and the counters.
#   -> {ok, errors: [text], fixed: [text], inodes, blocks_used, files, dirs, symlinks}
# ====================================================================================================================================================
export func fsck(dev, repair = false):
    let errors = []
    let fixed = []
    let fs = Fs(dev, {readonly: not repair})
    let bs = fs.bs
    let owner = {}
    let used_blocks = 0
    func claim(b, who):
        if b < fs.data_start or b >= fs.nblocks - 1:
            errors.append(who .. ": block " .. to_string(b) .. " is outside the data area")
            return false
        if has(owner, b):
            errors.append(who .. ": block " .. to_string(b) .. " is also owned by " .. owner[b])
            return false
        owner[b] = who
        used_blocks += 1
        return true
    let refs = {}
    let kinds = {}
    let live = []
    let counts = {file: 0, dir: 0, symlink: 0}
    # every allocated inode: its type, its blocks
    for ino in range(1, fs.ninodes):
        if not fs.inode_used(ino):
            continue
        let i = nil
        try:
            i = fs.iget(ino)
        catch e:
            errors.append("inode " .. to_string(ino) .. ": " .. e.message)
            continue
        let who = "inode " .. to_string(ino)
        let t = i.mode & S_IFMT
        if t != S_IFREG and t != S_IFDIR and t != S_IFLNK:
            errors.append(who .. ": bad file type " .. to_string(t))
            continue
        live.append(ino)
        kinds[ino] = t
        counts[kind_of(i.mode)] += 1
        let total = 0
        let expect_l = 0
        for e in i.ext:
            if e[1] == 0 or e[0] < expect_l:
                errors.append(who .. ": extents are not sorted or overlap")
            expect_l = e[0] + e[1]
            total += e[1]
            for b in range(e[2], e[2] + e[1]):
                claim(b, who)
        if i.ext_block != 0:
            claim(i.ext_block, who .. " (extent block)")
            total += 1
        if i.xattr_block != 0:
            claim(i.xattr_block, who .. " (xattrs)")
            total += 1
            try:
                fs.xattrs(i)
            catch e:
                errors.append(who .. ": " .. e.message)
        if total != i.blocks:
            errors.append(who .. ": block count " .. to_string(i.blocks) .. " but it owns " .. to_string(total))
        if t == S_IFDIR and i.size != (len(i.ext) and (i.ext[len(i.ext) - 1][0] + i.ext[len(i.ext) - 1][1]) * bs or 0):
            errors.append(who .. ": directory size does not match its blocks")
    # the directory tree from the root: reference counts, "." and ".."
    let seen = {}
    let stack = [[ROOT, ROOT]]
    seen[ROOT] = true
    refs[ROOT] = 2
    while len(stack) > 0:
        let item = stack.pop()
        let dino = item[0]
        let entries = nil
        try:
            entries = fs.dir_entries(dino)
        catch e:
            errors.append("directory " .. to_string(dino) .. ": " .. e.message)
            continue
        let dot = false
        let dotdot = false
        let subdirs = 0
        for e in entries:
            if e.name == ".":
                dot = true
                if e.ino != dino:
                    errors.append("directory " .. to_string(dino) .. ": . points to " .. to_string(e.ino))
            elif e.name == "..":
                dotdot = true
                if e.ino != item[1]:
                    errors.append("directory " .. to_string(dino) .. ": .. points to " .. to_string(e.ino) .. ", expected " .. to_string(item[1]))
            else:
                if not has(kinds, e.ino):
                    errors.append("directory " .. to_string(dino) .. ": entry '" .. e.name .. "' points to the unallocated inode " .. to_string(e.ino))
                    continue
                refs[e.ino] = (refs[e.ino] if has(refs, e.ino) else 0) + 1
                if kinds[e.ino] == S_IFDIR:
                    subdirs += 1
                    if has(seen, e.ino):
                        errors.append("directory " .. to_string(e.ino) .. " is reachable twice")
                    else:
                        seen[e.ino] = true
                        stack.append([e.ino, dino])
        if not dot or not dotdot:
            errors.append("directory " .. to_string(dino) .. ": missing . or ..")
        if dino != ROOT:
            refs[dino] = (refs[dino] if has(refs, dino) else 0) + 1      # its own "."
        else:
            refs[ROOT] = refs[ROOT] if has(refs, ROOT) else 0
        # a directory's link count: 2 + subdirectories
        refs[dino] = (refs[dino] if has(refs, dino) else 0) + subdirs
    # link counts and orphans
    let orphans = []
    for ino in live:
        let r = refs[ino] if has(refs, ino) else 0
        if r == 0 and ino != ROOT:
            errors.append("inode " .. to_string(ino) .. " is allocated but not reachable from the root")
            orphans.append(ino)
            continue
        let i = fs.iget(ino)
        let want = r
        if kinds[ino] == S_IFDIR:
            want = r           # references already include "." and the subdirectories; the parent's entry counted once
        if i.nlink != want:
            errors.append("inode " .. to_string(ino) .. ": link count " .. to_string(i.nlink) .. ", expected " .. to_string(want))
            if repair:
                fs.begin()
                i.nlink = want
                fs.iput(ino, i)
                fs.end()
                fixed.append("inode " .. to_string(ino) .. ": link count set to " .. to_string(want))
    if repair:
        for ino in orphans:
            fs.begin()
            let i = fs.iget(ino)
            for e in i.ext:
                for b in range(e[2], e[2] + e[1]):
                    owner[b] = nil
                    used_blocks -= 1
                fs.free_run(e[2], e[1])
            if i.ext_block != 0:
                owner[i.ext_block] = nil
                used_blocks -= 1
                fs.free_run(i.ext_block, 1)
            if i.xattr_block != 0:
                owner[i.xattr_block] = nil
                used_blocks -= 1
                fs.free_run(i.xattr_block, 1)
            fs.free_inode(ino)
            fs.end()
            fixed.append("orphan inode " .. to_string(ino) .. " freed")
    # the block bitmap against what the inodes own
    let leaked = 0
    let missing = 0
    for b in range(fs.data_start, fs.nblocks - 1):
        let used = fs.block_used(b)
        let owned = has(owner, b)
        if used and not owned:
            leaked += 1
            if repair:
                fs.begin()
                fs.set_block(b, false)
                fs.free_blocks += 1
                fs.sb_dirty = true
                fs.end()
        elif owned and not used:
            missing += 1
            errors.append("block " .. to_string(b) .. " (" .. owner[b] .. ") is in use but marked free")
            if repair:
                fs.begin()
                fs.set_block(b, true)
                fs.free_blocks -= 1
                fs.sb_dirty = true
                fs.end()
    if leaked > 0:
        errors.append(to_string(leaked) .. " allocated blocks belong to no inode (leaked)")
        if repair:
            fixed.append(to_string(leaked) .. " leaked blocks freed")
    if missing > 0 and repair:
        fixed.append(to_string(missing) .. " blocks marked used")
    # the free counters
    let free_b = (fs.nblocks - 1 - fs.data_start) - used_blocks
    let free_i = fs.ninodes - 1
    for ino in range(1, fs.ninodes):
        if fs.inode_used(ino):
            free_i -= 1
    if repair:
        fs.begin()
        fs.free_blocks = free_b
        fs.free_inodes = free_i
        fs.sb_dirty = true
        fs.end()
        fs.unmount()
    else:
        if fs.free_blocks != free_b:
            errors.append("the free block count is " .. to_string(fs.free_blocks) .. ", expected " .. to_string(free_b))
        if fs.free_inodes != free_i:
            errors.append("the free inode count is " .. to_string(fs.free_inodes) .. ", expected " .. to_string(free_i))
    return {ok: len(errors) == 0 or (repair and len(fixed) > 0), errors: errors, fixed: fixed, inodes: len(live), blocks_used: used_blocks,
            files: counts.file, dirs: counts.dir, symlinks: counts.symlink, replayed: fs.replayed}
