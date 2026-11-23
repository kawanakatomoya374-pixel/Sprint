# the TCP/IP stack (stdlib/netstack.sp) talking to a second stack over a virtual wire: ARP, ping, DHCP, DNS, UDP and TCP (also with lost frames)
import netstack
import str

let MASK32 = 0xFFFFFFFF
let wire_now = 0
let wire_loss = 0          # drop every n-th frame (0: none)
let wire_count = 0
let wire_drops = 0
let ends = []

class End:
    let q = nil
    let other = nil
    let stack = nil
    let busy = false
    let hook = nil
    func init(self):
        self.q = []
    func send(self, f):
        wire_count += 1
        if wire_loss > 0 and wire_count % wire_loss == 0:
            wire_drops += 1
            return nil
        self.other.q.append(f)
    func recv(self, ms):
        if len(self.q) == 0 and not self.other.busy and self.other.stack != nil:
            self.other.busy = true
            self.other.stack.poll(0)
            if self.other.hook != nil:
                self.other.hook()
            self.other.busy = false
        if len(self.q) > 0:
            return self.q.remove_at(0)
        wire_now += (ms if ms < 5 else 5)
        return nil

let ea = End()
let eb = End()
ea.other = eb
eb.other = ea
func clock():
    return wire_now
let A = netstack.Stack(ea, clock, [2, 0, 0, 0, 0, 1])
let B = netstack.Stack(eb, clock, [2, 0, 0, 0, 0, 2])
ea.stack = A
eb.stack = B
B.configure(netstack.ip("10.0.2.2"), netstack.ip("255.255.255.0"), 0, 0)

# ---- B's servers: DHCP (67), DNS (53), UDP echo (7), TCP echo (80) ----
let dhcp_s = B.udp_open(67)
let dns_s = B.udp_open(53)
let echo_s = B.udp_open(7)
let lst = B.tcp_listen(80)
let sconns = []
let leased = netstack.ip("10.0.2.15")

func dhcp_reply(req, mtype):
    let m = [2, 1, 6, 0]
    m.extend(req.slice(4, 8))
    m.extend([0, 0, 0x80, 0])
    for i in range(4):
        m.append(0)
    m.extend([10, 0, 2, 15])
    for i in range(8):
        m.append(0)
    m.extend(req.slice(28, 34))
    for i in range(10 + 64 + 128):
        m.append(0)
    m.extend([0x63, 0x82, 0x53, 0x63, 53, 1, mtype, 54, 4, 10, 0, 2, 2, 1, 4, 255, 255, 255, 0, 3, 4, 10, 0, 2, 2, 6, 4, 10, 0, 2, 2, 51, 4, 0, 0, 0x0e, 0x10, 255])
    return m

func serve():
    let r = dhcp_s.queue
    while len(r) > 0:
        let d = r.remove_at(0)[2]
        let mt = 0
        let i = 240
        while i < len(d) and d[i] != 255:
            if d[i] == 53:
                mt = d[i + 2]
            i += d[i + 1] + 2
        if mt == 1:
            B.udp_send(dhcp_s, MASK32, 68, dhcp_reply(d, 2))
        elif mt == 3:
            B.udp_send(dhcp_s, MASK32, 68, dhcp_reply(d, 5))
    while len(dns_s.queue) > 0:
        let r2 = dns_s.queue.remove_at(0)
        let q = r2[2]
        let o = 12
        while q[o] != 0:
            o += q[o] + 1
        o += 5
        let a = q.slice(0, o)
        a[2] = 0x81
        a[3] = 0x80
        a[7] = 1
        a.extend([0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34])
        B.udp_send(dns_s, r2[0], r2[1], a)
    while len(echo_s.queue) > 0:
        let r3 = echo_s.queue.remove_at(0)
        B.udp_send(echo_s, r3[0], r3[1], r3[2])
    while true:
        let c = B.tcp_accept(lst, 0)
        if c == nil:
            break
        sconns.append(c)
    for c in sconns:
        let d = B.tcp_recv(c, 4096, 0)
        if d == nil:
            continue
        if len(d) == 0:
            if c.state == "CLOSE_WAIT":
                B.tcp_close(c, 0)
            continue
        B.tcp_send(c, d.map(x => (x ^ 0x20) & 255))     # echo with bit 5 flipped

eb.hook = serve

func fnv(a):
    let h = 2166136261
    for x in a:
        h = ((h ^ x) * 16777619) & MASK32
    return h

# ---- checks ----
print("dhcp", A.dhcp(), netstack.ip_str(A.ip), netstack.ip_str(A.mask), netstack.ip_str(A.gw), netstack.ip_str(A.dns), A.lease)
let rtt = A.ping(netstack.ip("10.0.2.2"))
print("ping ok", rtt >= 0)
print("ping nobody", A.ping(netstack.ip("10.0.2.99"), 300))
print("dns", netstack.ip_str(A.resolve("Example.test")))
print("dns literal", netstack.ip_str(A.resolve("1.2.3.4")))
let s = A.udp_open(0)
A.udp_send(s, netstack.ip("10.0.2.2"), 7, [1, 2, 3, 4, 5])
let r = A.udp_recv(s, 500)
print("udp echo", r[2], netstack.ip_str(r[0]), r[1])
print("udp none", A.udp_recv(s, 50))

func tcp_round(n):
    let c = A.tcp_connect(netstack.ip("10.0.2.2"), 80, 8000)
    if c == nil:
        print("connect failed")
        return nil
    let data = []
    for i in range(n):
        data.append(65 + (i * 7) % 26)
    A.tcp_send(c, data)
    let got = []
    while len(got) < n:
        let p = A.tcp_recv(c, 2000, 8000)
        if p == nil or len(p) == 0:
            break
        got.extend(p)
    print("tcp", n, "bytes back", len(got), "match", fnv(got) == fnv(data.map(x => x ^ 0x20)))
    A.tcp_close(c)
    let eof = A.tcp_recv(c, 10, 2000)
    print("tcp after close", len(c.rbuf), c.state)

tcp_round(10)
tcp_round(20000)
wire_loss = 9
tcp_round(20000)
print("frames dropped", wire_drops > 0)
wire_loss = 0
let refused = A.tcp_connect(netstack.ip("10.0.2.2"), 81, 1000)
print("refused", refused)
