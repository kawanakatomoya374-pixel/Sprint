# fstest: starts the file system server and uses it through fsclient (the QEMU test os-disk-test runs this as the init program).
import psys as sys
import fsclient
import str

let srv = sys.spawn("fsd")
print("fstest: fsd is pid", srv)
let fs = fsclient.connect()
print("fstest: connected")
print("fstest: root", len(fs.listdir("/")), "entries")
if fs.exists("/hello.txt"):
    print("fstest: /hello.txt:", fs.read_file("/hello.txt").trim())
fs.mkdir("/docs")
fs.write_file("/docs/a.txt", "written through the file system server\n")
print("fstest: read back:", fs.read_file("/docs/a.txt").trim())
print("fstest: stat", fs.stat("/docs/a.txt").kind, fs.stat("/docs/a.txt").size)
# a file larger than the shared buffer, with every byte value
let big = ""
for i in range(300):
    let row = ""
    for j in range(1000):
        row = row .. "abcdefghij"[(i + j) % 10]
    big = big .. row
let t0 = sys.ms()
fs.write_file("/docs/big.txt", big)
let back = fs.read_file("/docs/big.txt")
print("fstest: big file", len(big), "bytes, round trip", "ok" if back == big else "DIFFERENT", "in", sys.ms() - t0, "ms")
fs.write("/docs/big.txt", "XYZ", 5)
print("fstest: partial write:", fs.read("/docs/big.txt", 3, 8))
print("fstest: listing:", fs.listdir("/docs").map(e => e.name).join(","))
fs.rename("/docs/a.txt", "/docs/b.txt")
fs.unlink("/docs/big.txt")
print("fstest: after rename/unlink:", fs.listdir("/docs").map(e => e.name).join(","))
try:
    fs.read_file("/nope")
catch e:
    print("fstest: missing file:", e.kind)
try:
    fs.mkdir("/docs")
catch e:
    print("fstest: mkdir again:", e.kind)
let sf = fs.statfs()
print("fstest: free blocks", sf.free_blocks > 0)
fs.quit()
print("fstest: fsd exited with", sys.wait(srv))
print("fstest: done")
