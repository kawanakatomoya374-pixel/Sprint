# fsclient: the client side of the file system server (fsd). Any process can use it:
#
#   import fsclient
#   let fs = fsclient.connect()                 # finds the server by name and shares a buffer with it
#   fs.write_file("/home/note.txt", "hello")
#   print(fs.read_file("/home/note.txt"), fs.listdir("/"), fs.stat("/home/note.txt").size)
#
# One request is in flight at a time. The calls throw error(kind, message) with SprintFS's kinds (ENOENT, EEXIST, ...).
# The client waits in ipc.recv_from() for the server's answer, so a process that also receives other messages should use fs from one place only.
import io
import ipc
import psys
import str
import sslcore

const BUF = 65536
const CHUNK = 60000

func fail(kind, msg):
    throw error(kind, msg)

export class Stat:
    let kind = "file"
    let size = 0
    let mode = 0
    let nlink = 0
    let mtime = 0

export class Client:
    let server = 0
    let seg = nil
    let backlog = nil            # messages from other processes that arrived while a call waited for the server's answer (a program that serves
                                 # other clients itself, like linuxd, takes them from here instead of losing them)
    func init(self, server):
        self.server = server
        self.backlog = []
        self.seg = ipc.shm_create(BUF)
        self.call("attach\t" .. to_string(self.seg[0]))
    # one request / answer; returns the fields after "ok"
    func call(self, req):
        io.flush()
        ipc.send(self.server, req)
        while true:
            let m = ipc.recv_from()
            if m[0] != self.server:
                if len(self.backlog) < 4096:
                    self.backlog.append(m)
                continue
            let f = m[1].split("\t")
            if f[0] == "ok":
                return f.slice(1, len(f))
            fail(f[1], f[2])
    func stat(self, path):
        let f = self.call("stat\t" .. path)
        let s = Stat()
        s.kind = f[0]
        s.size = to_int(f[1])
        s.mode = to_int(f[2])
        s.nlink = to_int(f[3])
        s.mtime = to_int(f[4])
        return s
    func lstat(self, path):
        let f = self.call("lstat\t" .. path)
        let s = Stat()
        s.kind = f[0]
        s.size = to_int(f[1])
        s.mode = to_int(f[2])
        s.nlink = to_int(f[3])
        s.mtime = to_int(f[4])
        return s
    func symlink(self, target, path):
        self.call("symlink\t" .. target .. "\t" .. path)
    func readlink(self, path):
        return self.call("readlink\t" .. path)[0]
    func chmod(self, path, mode):
        self.call("chmod\t" .. path .. "\t" .. to_string(mode))
    func exists(self, path):
        return self.call("exists\t" .. path)[0] == "1"
    # names of a directory: [{kind, size, name}]
    func listdir(self, path = "/"):
        let n = to_int(self.call("list\t" .. path)[0])
        let out = []
        if n == 0:
            return out
        for line in ipc.shm_read(self.seg[1], 0, n).split("\n"):
            let f = line.split("\t")
            out.append({kind: f[0], size: to_int(f[1]), name: f[2]})
        return out
    # up to n bytes at offset off, as a string (all the rest when n < 0)
    func read(self, path, off = 0, n = -1):
        let want = n if n >= 0 else self.stat(path).size - off
        let parts = []
        let got = 0
        while got < want:
            let k = to_int(self.call("read\t" .. path .. "\t" .. to_string(off + got) .. "\t" .. to_string(min_int(CHUNK, want - got)))[0])
            if k == 0:
                break
            parts.append(ipc.shm_read(self.seg[1], 0, k))
            got += k
        return parts.join("")
    # the same as read(), binary safe: a typed.u8
    func read_bytes(self, path, off = 0, n = -1):
        let want = n if n >= 0 else self.stat(path).size - off
        let parts = []
        let got = 0
        while got < want:
            let k = to_int(self.call("read\t" .. path .. "\t" .. to_string(off + got) .. "\t" .. to_string(min_int(CHUNK, want - got)))[0])
            if k == 0:
                break
            parts.append(ipc.shm_bytes(self.seg[1], 0, k))
            got += k
        return sslcore.concat(parts)
    # the same as write() for a typed.u8
    func write_bytes(self, path, data, off = 0, truncate = false):
        let done = 0
        let first = truncate
        if len(data) == 0:
            self.call("write\t" .. path .. "\t" .. to_string(off) .. "\t0\t" .. ("t" if first else "-"))
            return 0
        while done < len(data):
            let n = min_int(CHUNK, len(data) - done)
            ipc.shm_put(self.seg[1], 0, data.slice(done, done + n))
            self.call("write\t" .. path .. "\t" .. to_string(off + done) .. "\t" .. to_string(n) .. "\t" .. ("t" if first else "-"))
            first = false
            done += n
        return done
    func read_file(self, path):
        return self.read(path, 0, -1)
    # writes data at offset off (creating the file); truncate = true first empties it
    func write(self, path, data, off = 0, truncate = false):
        let done = 0
        let first = truncate
        if len(data) == 0:
            self.call("write\t" .. path .. "\t" .. to_string(off) .. "\t0\t" .. ("t" if first else "-"))
            return 0
        while done < len(data):
            let n = min_int(CHUNK, len(data) - done)
            ipc.shm_write(self.seg[1], 0, data.slice(done, done + n))
            self.call("write\t" .. path .. "\t" .. to_string(off + done) .. "\t" .. to_string(n) .. "\t" .. ("t" if first else "-"))
            first = false
            done += n
        return done
    func write_file(self, path, data):
        return self.write(path, data, 0, true)
    func truncate(self, path, size):
        self.call("truncate\t" .. path .. "\t" .. to_string(size))
    func mkdir(self, path):
        self.call("mkdir\t" .. path)
    func unlink(self, path):
        self.call("unlink\t" .. path)
    func rmdir(self, path):
        self.call("rmdir\t" .. path)
    func rename(self, old, new):
        self.call("rename\t" .. old .. "\t" .. new)
    func sync(self):
        self.call("sync")
    func statfs(self):
        let f = self.call("statfs")
        return {free_blocks: to_int(f[0]), blocks: to_int(f[1])}
    # ask the server to sync and exit (for tests and shutdown)
    func quit(self):
        self.call("quit")

func min_int(a, b):
    return a if a < b else b

# waits (up to `timeout_ms`) for the server to register, then connects
export func connect(timeout_ms = 5000):
    let t0 = psys.ms()
    while true:
        let pid = ipc.lookup("fs")
        if pid != nil:
            return Client(pid)
        if psys.ms() - t0 > timeout_ms:
            fail("ENODEV", "no file system server")
        psys.sleep_ms(5)
