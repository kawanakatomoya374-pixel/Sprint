# netlink: the network stack's side of the frame interface to netd (see os/user/netd.sp). A Link gives netstack.Stack its send() and recv():
# frames travel through a shared segment, one at a time, announced with messages.
import ipc
import uio
import psys

export class Link:
    let pid = 0
    let seg = nil
    let va = 0
    let mac = nil
    let pending = nil
    func init(self, wait_ms = 5000):
        self.pending = []
        let t0 = psys.ms()
        while true:
            self.pid = ipc.lookup("net")
            if self.pid != nil and self.pid > 0:
                break
            if psys.ms() - t0 > wait_ms:
                throw error("ENODEV", "netd is not running")
            psys.sleep_ms(20)
        self.seg = ipc.shm_create(4096)
        self.va = self.seg[1]
        ipc.send(self.pid, "sub\t" .. to_string(self.seg[0]))
        let r = self.answer("ok")
        let m = r[1].split(":")
        self.mac = m.map(h => hex(h))

    # the next message from netd: an "rx" notice is put aside, anything else of the given kind is returned
    func answer(self, kind):
        while true:
            let m = ipc.recv_from()
            if m[0] != self.pid:
                continue
            let q = m[1].split("\t")
            if q[0] == "rx":
                self.pending.append(to_int(q[1]))
            elif q[0] == kind:
                return q
            elif q[0] == "err":
                throw error("EIO", q[1])

    func send(self, f):
        for i in range(len(f)):
            uio.poke8(self.va + 2048 + i, f[i])
        ipc.send(self.pid, "tx\t" .. to_string(len(f)))
        self.answer("ok")

    func take(self, n):
        let f = []
        f.reserve(n)
        for i in range(n):
            f.append(uio.peek8(self.va + i))
        ipc.send(self.pid, "ack")
        return f

    # the next frame, waiting up to ms (0: do not wait); nil if none
    func recv(self, ms):
        if len(self.pending) > 0:
            return self.take(self.pending.remove_at(0))
        let m = nil
        if ms <= 0:
            m = ipc.recv_from(false)
        else:
            m = ipc.recv_from(true, ms)
        if m == nil or m[0] != self.pid:
            return nil
        let q = m[1].split("\t")
        if q[0] == "rx":
            return self.take(to_int(q[1]))
        return nil

    func close(self):
        ipc.send(self.pid, "unsub")
        self.answer("ok")

func hex(h):
    let v = 0
    for i in range(len(h)):
        let c = h[i]
        v = v * 16 + (c - 48 if c <= 57 else c - 87)
    return v
