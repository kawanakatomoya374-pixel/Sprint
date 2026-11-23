# SprintFS fsck: damage a file system in several ways, see it reported, repair it, and find it clean
import sprintfs

let dev = sprintfs.MemDevice(1024, 4096)
sprintfs.mkfs(dev)
let fs = sprintfs.mount(dev)
fs.mkdir("/d")
fs.write_file("/d/one", "one")
fs.write_file("/d/two", "two two")
fs.link("/d/two", "/d/alias")
fs.symlink("/d/one", "/s")
let r0 = sprintfs.fsck(dev)
print("start", r0.ok, r0.files, r0.dirs, r0.symlinks)
# 1. a wrong link count
fs.begin()
let ino = fs.resolve("/d/two", true)
let i = fs.iget(ino)
i.nlink = 5
fs.iput(ino, i)
fs.end()
# 2. leaked blocks
fs.begin()
fs.alloc_blocks(3, 300)
fs.end()
# 3. an orphan inode with data
fs.begin()
let orphan = fs.alloc_inode()
let oi = fs.iget(ino)
oi.nlink = 1
oi.ext = []
oi.blocks = 0
oi.size = 0
fs.iput(orphan, oi)
fs.end()
fs.unmount()
let r1 = sprintfs.fsck(dev)
print("damaged", r1.ok, len(r1.errors) >= 3)
for e in r1.errors:
    print("  found:", e)
let r2 = sprintfs.fsck(dev, true)
for f in r2.fixed:
    print("  fixed:", f)
let r3 = sprintfs.fsck(dev)
print("repaired", r3.ok, r3.errors)
let fs2 = sprintfs.mount(dev)
print(fs2.read_file("/d/alias"), fs2.stat("/d/two").nlink, fs2.listdir("/d"))
fs2.unmount()
# a flipped bit in an inode is caught by its checksum
let m = sprintfs.mount(dev)
let sf = m.statfs()
let itab_block = 1 + ((1024 + 4096 * 8 - 1) // (4096 * 8)) + ((sf.inodes + 4095 * 0 + 32767) // 32768)
m.unmount()
let blk = dev.read(itab_block)
blk[5 * 256 + 20] = blk[5 * 256 + 20] ^ 1
dev.write(itab_block, blk)
let r4 = sprintfs.fsck(dev)
print("bit flip", r4.ok, len(r4.errors) > 0)
# a damaged primary superblock falls back to the backup copy
let dev2 = sprintfs.MemDevice(256, 4096)
sprintfs.mkfs(dev2)
let sb = dev2.read(0)
sb[10] = sb[10] ^ 255
dev2.write(0, sb)
let m2 = sprintfs.mount(dev2, {readonly: true})
print("backup superblock", m2.statfs().blocks, m2.listdir("/"))
# not a file system
let dev3 = sprintfs.MemDevice(128, 4096)
try:
    sprintfs.mount(dev3)
catch e:
    print(e.kind)
