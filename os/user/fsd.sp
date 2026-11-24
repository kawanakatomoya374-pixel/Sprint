# fsd: the file system server. A user process (not part of the kernel) that owns the ATA disk (the kernel opens its I/O ports) and a SprintFS volume
# on it, and serves other processes over messages. Clients are found with ipc.lookup("fs"); the protocol (see fsclient.sp) is one request message
# per operation, tab separated, answered by "ok<TAB>..." or "err<TAB>KIND<TAB>message". File contents travel through a shared-memory segment
# each client sets up with "attach" (the kernel tells fsd who sent a message, so a request cannot pretend to be another process).
import io
import ipc
import uata
import uvblk
import sprintfs
import str

func log(s):
    print("[fsd] " .. s)

let volume = nil
let disks = uvblk.probe()
for d in (disks if len(disks) > 0 else uata.probe()):
    if volume == nil:
        try:
            volume = sprintfs.mount(d)
            log("mounted SprintFS from " .. d.model .. " (" .. to_string(d.blocks() * 4096 // 1048576) .. " MiB)")
        catch e:
            log("disk " .. d.model .. ": not SprintFS (" .. e.message .. ")")
if volume == nil:
    log("no SprintFS volume found")
    ipc.register("fs")
    # keep answering so that clients get a clear error instead of waiting for ever
let clients = {}      # pid -> [address, bytes] of its shared buffer

func ok(rest = ""):
    return "ok" .. ("\t" .. rest if rest != "" else "")

func fail(kind, msg):
    return "err\t" .. kind .. "\t" .. msg

func buf_of(src):
    return clients[to_string(src)] if to_string(src) in clients else nil

func handle(src, q):
    let op = q[0]
    if op == "attach":
        let seg = ipc.shm_open(to_int(q[1]))
        clients[to_string(src)] = seg
        return ok(to_string(seg[1]))
    if volume == nil:
        return fail("ENODEV", "no file system volume")
    if op == "stat":
        let s = volume.stat(q[1])
        return ok(s.kind .. "\t" .. to_string(s.size) .. "\t" .. to_string(s.mode) .. "\t" .. to_string(s.nlink) .. "\t" .. to_string(s.mtime))
    if op == "lstat":
        let s2 = volume.lstat(q[1])
        return ok(s2.kind .. "\t" .. to_string(s2.size) .. "\t" .. to_string(s2.mode) .. "\t" .. to_string(s2.nlink) .. "\t" .. to_string(s2.mtime))
    if op == "symlink":
        volume.symlink(q[1], q[2])
        return ok()
    if op == "readlink":
        return ok(volume.readlink(q[1]))
    if op == "chmod":
        volume.chmod(q[1], to_int(q[2]))
        return ok()
    if op == "exists":
        return ok("1" if volume.exists(q[1]) else "0")
    if op == "list":
        let b = buf_of(src)
        if b == nil:
            return fail("EINVAL", "attach a buffer first")
        let lines = []
        for name in volume.listdir(q[1]):
            let st = volume.lstat(q[1] .. ("" if q[1] == "/" else "/") .. name)
            lines.append(st.kind .. "\t" .. to_string(st.size) .. "\t" .. name)
        let text = lines.join("\n")
        if len(text) > b[1]:
            return fail("ERANGE", "directory listing larger than the shared buffer")
        ipc.shm_write(b[0], 0, text)
        return ok(to_string(len(text)))
    if op == "read":
        let b = buf_of(src)
        if b == nil:
            return fail("EINVAL", "attach a buffer first")
        let f = volume.open(q[1], "r")
        f.seek(to_int(q[2]))
        let want = to_int(q[3])
        if want > b[1]:
            want = b[1]
        let data = f.read(want)
        f.close()
        if len(data) > 0:
            ipc.shm_put(b[0], 0, data)
        return ok(to_string(len(data)))
    if op == "write":
        let b = buf_of(src)
        if b == nil:
            return fail("EINVAL", "attach a buffer first")
        let n = to_int(q[3])
        if n > b[1]:
            return fail("ERANGE", "write larger than the shared buffer")
        let f = volume.open(q[1], "r+" if volume.exists(q[1]) else "w+")
        if q[4] == "t":
            f.truncate(0)
        f.seek(to_int(q[2]))
        f.write(ipc.shm_bytes(b[0], 0, n))
        f.close()
        return ok(to_string(n))
    if op == "truncate":
        volume.truncate(q[1], to_int(q[2]))
        return ok()
    if op == "mkdir":
        volume.mkdir(q[1])
        return ok()
    if op == "unlink":
        volume.unlink(q[1])
        return ok()
    if op == "rmdir":
        volume.rmdir(q[1])
        return ok()
    if op == "rename":
        volume.rename(q[1], q[2])
        return ok()
    if op == "sync":
        volume.sync()
        return ok()
    if op == "statfs":
        let s = volume.statfs()
        return ok(to_string(s.free_blocks) .. "\t" .. to_string(s.blocks))
    return fail("ENOSYS", "unknown operation " .. op)

if volume != nil:
    ipc.register("fs")
io.flush()
log("serving as \"fs\", pid " .. to_string(ipc.lookup("fs")))
let running = true
while running:
    io.flush()
    let m = ipc.recv_from()
    let src = m[0]
    let q = m[1].split("\t")
    let reply = nil
    if q[0] == "quit":
        if volume != nil:
            volume.sync()
        reply = ok()
        running = false
    else:
        try:
            reply = handle(src, q)
        catch e:
            reply = fail(e.kind, e.message)
    ipc.send(src, reply)
log("bye")
