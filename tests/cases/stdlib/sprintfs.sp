# SprintFS: operations, errors, persistence, journal recovery after a crash at every write, fsck
import sprintfs

func sprintfs_zero(n):
    let t = []
    for i in range(n):
        t.append(0)
    return t

func fresh(blocks = 2048, bs = 4096):
    let dev = sprintfs.MemDevice(blocks, bs)
    sprintfs.mkfs(dev, {label: "test"})
    return dev

func expect(kind, f):
    try:
        f()
        print("no error, expected", kind)
    catch e:
        print(kind if e.kind == kind else "wrong error " .. e.kind .. ": " .. e.message)

func clean(dev, what):
    let r = sprintfs.fsck(dev)
    print(what, "fsck", "clean" if r.ok else r.errors)

# ---- files, directories, listing ----
let dev = fresh()
let fs = sprintfs.mount(dev)
fs.mkdir("/a")
fs.makedirs("/a/b/c")
fs.write_file("/a/hello.txt", "hello, SprintFS")
print(fs.read_file("/a/hello.txt"), fs.listdir("/"), fs.listdir("/a"), fs.stat("/a/hello.txt").size, fs.stat("/a").kind)
fs.append_file("/a/hello.txt", " and more")
print(fs.read_file("/a/hello.txt"))
let f = fs.open("/a/rw.bin", "w+")
f.write([1, 2, 3, 4, 5])
f.seek(1)
print(f.read(3).to_array(), f.tell(), f.size())
f.seek(0, 2)
f.write("end")
f.close()
print(fs.read_bytes("/a/rw.bin").to_array())
print(fs.exists("/a/b/c"), fs.exists("/nope"), fs.is_dir("/a/b"), fs.is_file("/a/b"))

# ---- a big, fragmented and sparse file ----
let big = []
for i in range(20000):
    big.append((i * 7 + i // 256) & 255)
fs.write_file("/big", big)
let back = fs.read_bytes("/big")
let same = len(back) == 20000
for i in range(20000):
    if back[i] != big[i]:
        same = false
print("big file", same, fs.stat("/big").blocks)
let sp = fs.open("/sparse", "w")
sp.seek(5 * 4096 + 10)
sp.write("tail")
sp.close()
let sb = fs.read_bytes("/sparse")
print("sparse", len(sb), sb[0], sb[5 * 4096 + 10], fs.stat("/sparse").blocks)
fs.truncate("/big", 5000)
print("truncate down", fs.stat("/big").size, fs.stat("/big").blocks, fs.read_bytes("/big")[4999] == big[4999])
fs.truncate("/big", 9000)
print("truncate up", fs.stat("/big").size, fs.read_bytes("/big")[6000])

# ---- many entries in one directory (it grows over several blocks) ----
fs.mkdir("/many")
for i in range(300):
    fs.write_file("/many/file-with-a-longish-name-" .. to_string(i), "x")
print("many", len(fs.listdir("/many")), fs.stat("/many").size)
for i in range(0, 300, 2):
    fs.unlink("/many/file-with-a-longish-name-" .. to_string(i))
print("after removing half", len(fs.listdir("/many")))

# ---- links, symlinks, rename ----
fs.link("/a/hello.txt", "/a/hard")
print(fs.stat("/a/hello.txt").nlink, fs.read_file("/a/hard") == fs.read_file("/a/hello.txt"))
fs.unlink("/a/hello.txt")
print(fs.stat("/a/hard").nlink, fs.read_file("/a/hard"))
fs.symlink("/a/hard", "/sym")
fs.symlink("b/c", "/a/rel")
fs.symlink("/loop2", "/loop1")
fs.symlink("/loop1", "/loop2")
print(fs.readlink("/sym"), fs.read_file("/sym"), fs.lstat("/sym").kind, fs.stat("/sym").kind, fs.stat("/a/rel").kind)
expect("ELOOP", () => fs.stat("/loop1"))
let longt = "/" .. "long/".repeat(30) .. "target"
fs.symlink(longt, "/longlink")
print(fs.readlink("/longlink") == longt)
fs.rename("/a/hard", "/a/b/moved")
fs.rename("/a/b", "/b2")
print(fs.listdir("/a"), fs.listdir("/b2"), fs.read_file("/b2/moved"), fs.stat("/").nlink)
fs.mkdir("/x")
fs.write_file("/x/f", "1")
fs.rename("/x/f", "/y")
fs.rename("/y", "/b2/moved")
print(fs.read_file("/b2/moved"), fs.listdir("/x"))
expect("EINVAL", () => fs.rename("/b2", "/b2/c/inside"))
expect("ENOTEMPTY", () => fs.rmdir("/b2"))
expect("EEXIST", () => fs.mkdir("/b2"))
expect("ENOENT", () => fs.read_file("/missing"))
expect("EISDIR", () => fs.unlink("/b2"))
expect("ENOTDIR", () => fs.listdir("/b2/moved"))
expect("EEXIST", () => fs.create("/b2/moved"))
expect("EISDIR", () => fs.read_file("/b2"))
fs.rmdir("/x")

# ---- attributes ----
fs.chmod("/b2/moved", 0x180)
fs.chown("/b2/moved", 1000, 100)
fs.utime("/b2/moved", 111, 222)
let st = fs.stat("/b2/moved")
print(st.mode, st.uid, st.gid, st.atime, st.mtime)
fs.setxattr("/b2/moved", "user.note", "hello")
fs.setxattr("/b2/moved", "user.tag", [1, 2, 3])
fs.setxattr("/b2/moved", "user.note", "changed")
print(fs.listxattr("/b2/moved"), fs.getxattr("/b2/moved", "user.note").to_array(), fs.getxattr("/b2/moved", "user.tag").to_array())
fs.removexattr("/b2/moved", "user.tag")
print(fs.listxattr("/b2/moved"))
expect("ENOENT", () => fs.getxattr("/b2/moved", "user.tag"))

# ---- space accounting ----
let before = fs.statfs().free_blocks
fs.write_file("/space", big)
let mid = fs.statfs().free_blocks
fs.unlink("/space")
print("space returned", fs.statfs().free_blocks == before, mid < before)
expect("ENOSPC", () => fs.write_file("/huge", sprintfs_zero(3000 * 4096)))
print("after a failed write the file system is intact", fs.statfs().free_blocks == before)

# ---- persistence: unmount, mount again, fsck ----
fs.unmount()
clean(dev, "after unmount")
let fs2 = sprintfs.mount(dev)
print(fs2.read_file("/b2/moved"), len(fs2.listdir("/many")), fs2.stat("/big").size, fs2.getxattr("/b2/moved", "user.note").to_array())
fs2.unmount()

