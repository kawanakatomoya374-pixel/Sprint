# netstack: a small TCP/IP stack written in Sprint: Ethernet, ARP, IPv4, ICMP echo, UDP, DHCP client, DNS client (A records) and TCP (client and server).
#
#   import netstack
#   let st = netstack.Stack(link, clock_ms, mac)       # link.send(frame) and link.recv(timeout_ms) -> frame or nil; frames are arrays of bytes
#   st.dhcp()                                          # or st.configure(ip, mask, gateway, dns) with netstack.ip("10.0.2.15") ...
#   let ip = st.resolve("example.com")                 # an IPv4 address as an int (nil when the name does not resolve)
#   let c = st.tcp_connect(ip, 80)
#   st.tcp_send(c, str.to_bytes("GET / HTTP/1.0\r\n\r\n"))
#   let part = st.tcp_recv(c, 4096, 2000)              # an array of bytes; [] at the end of the stream; nil when nothing came in time
#   st.tcp_close(c)
#
# The stack does not run by itself: every call that waits (connect, recv, dhcp, ...) polls the link meanwhile, and poll(ms) runs it explicitly.
# Addresses are ints (0x0A00020F is 10.0.2.15); ip("a.b.c.d") and ip_str(n) convert.
# Not done: IP fragmentation (fragments are dropped, packets go out with DF), TCP options other than MSS, congestion control (a fixed window), out-of-order
# segments (dropped; the peer retransmits), urgent data, IPv6.
import str

const MASK32 = 0xFFFFFFFF
const ETH_IP = 0x0800
const ETH_ARP = 0x0806
const BCAST_MAC = [255, 255, 255, 255, 255, 255]
const MSS_DEFAULT = 1460
const SEND_LIMIT = 65536
const RECV_LIMIT = 65535
const WINDOW_CAP = 24000

const F_FIN = 0x01
const F_SYN = 0x02
const F_RST = 0x04
const F_PSH = 0x08
const F_ACK = 0x10

# ---- byte helpers ------------------------------------------------------------------------------------------------------------------
func u16(b, o):
    return (b[o] << 8) | b[o + 1]

func u32(b, o):
    return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]

func p16(a, v):
    a.append((v >> 8) & 255)
    a.append(v & 255)

func p32(a, v):
    a.append((v >> 24) & 255)
    a.append((v >> 16) & 255)
    a.append((v >> 8) & 255)
    a.append(v & 255)

func put16(a, o, v):
    a[o] = (v >> 8) & 255
    a[o + 1] = v & 255

# the Internet checksum of b[o .. o + n), starting from sum0 (the pseudo header's sum)
func csum(b, o, n, sum0):
    let s = sum0
    let i = o
    let last = o + n - 1
    while i < last:
        s += (b[i] << 8) | b[i + 1]
        i += 2
    if i == last:
        s += b[i] << 8
    while (s >> 16) != 0:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

func pseudo_sum(src, dst, proto, n):
    let s = (src >> 16) + (src & 0xFFFF) + (dst >> 16) + (dst & 0xFFFF) + proto + n
    return s

export func ip(s):
    let p = s.split(".")
    if len(p) != 4:
        return nil
    let v = 0
    for x in p:
        let n = to_int(x)
        if n == nil or n < 0 or n > 255:
            return nil
        v = (v << 8) | n
    return v

export func ip_str(n):
    return to_string((n >> 24) & 255) .. "." .. to_string((n >> 16) & 255) .. "." .. to_string((n >> 8) & 255) .. "." .. to_string(n & 255)

func hex2(v):
    let d = "0123456789abcdef"
    return d.slice((v >> 4) & 15, ((v >> 4) & 15) + 1) .. d.slice(v & 15, (v & 15) + 1)

export func mac_str(m):
    return m.map(b => hex2(b)).join(":")

# is a before b in sequence-number space (mod 2^32)?
func seq_lt(a, b):
    let d = (a - b) & MASK32
    return d >= 0x80000000

func seq_le(a, b):
    return a == b or seq_lt(a, b)

func same(a, b):
    if len(a) != len(b):
        return false
    for i in range(len(a)):
        if a[i] != b[i]:
            return false
    return true

func fail(kind, msg):
    throw error(kind, msg)

# ---- a TCP connection ------------------------------------------------------------------------------------------------------------------
export class Conn:
    let state = "CLOSED"
    let lport = 0
    let rip = 0
    let rport = 0
    let iss = 0
    let irs = 0
    let snd_una = 0
    let snd_nxt = 0
    let snd_wnd = 0
    let rcv_nxt = 0
    let mss = 536
    let sbuf = nil               # bytes from snd_una on: the unacknowledged data followed by the data not yet sent
    let rbuf = nil               # bytes received and not yet read
    let fin_pending = false      # close() was called: send a FIN once the data is out
    let fin_sent = false
    let fin_seq = 0
    let fin_acked = false
    let fin_rcvd = false
    let rto = 300
    let rto_at = 0
    let retries = 0
    let err = nil
    let listener = nil
    let tw_at = 0
    func init(self):
        self.sbuf = []
        self.rbuf = []

export class Listener:
    let port = 0
    let queue = nil
    func init(self, port):
        self.port = port
        self.queue = []

export class UdpSocket:
    let port = 0
    let queue = nil
    func init(self, port):
        self.port = port
        self.queue = []

# ---- the stack ---------------------------------------------------------------------------------------------------------------------------
export class Stack:
    let link = nil
    let clock = nil
    let mac = nil
    let ip = 0
    let mask = 0
    let gw = 0
    let dns = 0
    let dns_port = 53
    let lease = 0
    let arp = nil
    let udp = nil
    let conns = nil
    let listeners = nil
    let pings = nil
    let dns_cache = nil
    let ipid = 1
    let next_port = 49152
    let isn_n = 0
    let dns_id = 0x4100
    let ping_seq = 0
    let rx_count = 0
    let tx_count = 0
    let drops = 0
    func init(self, link, clock, mac):
        self.link = link
        self.clock = clock
        self.mac = mac
        self.arp = {}
        self.udp = {}
        self.conns = {}
        self.listeners = {}
        self.pings = {}
        self.dns_cache = {}
        self.isn_n = clock() * 7919

    func configure(self, ipaddr, mask, gw, dns):
        self.ip = ipaddr
        self.mask = mask
        self.gw = gw
        self.dns = dns

    # ---- the loop ----
    # take one frame off the link (waiting up to ms), act on it, and run the timers
    func poll(self, ms):
        let f = self.link.recv(ms)
        if f != nil:
            self.rx_frame(f)
        self.timers()
        return f != nil

    # poll until cond() is true or ms have passed; returns whether cond became true
    func run_until(self, cond, ms):
        let t0 = self.clock()
        while true:
            if cond():
                return true
            let left = ms - (self.clock() - t0)
            if left <= 0:
                return false
            self.poll(left if left < 50 else 50)

    func send_eth(self, dmac, etype, payload):
        let f = []
        f.reserve(14 + len(payload))
        f.extend(dmac)
        f.extend(self.mac)
        p16(f, etype)
        f.extend(payload)
        if len(f) < 60:
            for i in range(60 - len(f)):
                f.append(0)
        self.tx_count += 1
        self.link.send(f)

    func rx_frame(self, f):
        if len(f) < 14:
            return nil
        self.rx_count += 1
        let dm = f.slice(0, 6)
        if not (same(dm, self.mac) or same(dm, BCAST_MAC)):
            return nil
        let et = u16(f, 12)
        if et == ETH_ARP:
            self.arp_in(f)
        elif et == ETH_IP:
            self.ip_in(f)

    # ---- ARP ----
    func arp_packet(self, op, tmac, tip):
        let p = [0, 1, 8, 0, 6, 4]
        p16(p, op)
        p.extend(self.mac)
        p32(p, self.ip)
        p.extend(tmac)
        p32(p, tip)
        return p

    func arp_in(self, f):
        if len(f) < 42 or u16(f, 14) != 1 or u16(f, 16) != ETH_IP:
            return nil
        let op = u16(f, 20)
        let smac = f.slice(22, 28)
        let sip = u32(f, 28)
        let tip = u32(f, 38)
        if sip != 0:
            self.arp[sip] = [smac, self.clock() + 60000]
        if op == 1 and tip == self.ip and self.ip != 0:
            self.send_eth(smac, ETH_ARP, self.arp_packet(2, smac, sip))

    func is_bcast(self, dst):
        if dst == MASK32:
            return true
        let hostmask = (~self.mask) & MASK32
        return self.mask != 0 and (dst & hostmask) == hostmask and (dst & self.mask) == (self.ip & self.mask)

    # the Ethernet address for an IP destination (asking with ARP when it is not known); nil if nobody answers
    func mac_for(self, dst):
        if self.is_bcast(dst):
            return BCAST_MAC
        let hop = dst
        if (dst & self.mask) != (self.ip & self.mask):
            hop = self.gw
        let e = self.arp[hop]
        if e != nil and e[1] > self.clock():
            return e[0]
        for attempt in range(4):
            self.send_eth(BCAST_MAC, ETH_ARP, self.arp_packet(1, [0, 0, 0, 0, 0, 0], hop))
            let ok = self.run_until(() => self.arp[hop] != nil and self.arp[hop][1] > self.clock(), 300)
            if ok:
                return self.arp[hop][0]
        return nil

    # ---- IPv4 ----
    func ip_send(self, proto, dst, payload, src = nil):
        let sa = self.ip if src == nil else src
        let dmac = nil
        if self.ip == 0:
            dmac = BCAST_MAC           # not configured yet (DHCP): everything goes out as a broadcast
        else:
            dmac = self.mac_for(dst)
        if dmac == nil:
            return false
        let h = [0x45, 0]
        p16(h, 20 + len(payload))
        p16(h, self.ipid)
        self.ipid = (self.ipid + 1) & 0xFFFF
        p16(h, 0x4000)
        h.append(64)
        h.append(proto)
        p16(h, 0)
        p32(h, sa)
        p32(h, dst)
        put16(h, 10, csum(h, 0, 20, 0))
        h.extend(payload)
        self.send_eth(dmac, ETH_IP, h)
        return true

    func ip_in(self, f):
        let n = len(f) - 14
        if n < 20 or (f[14] >> 4) != 4:
            return nil
        let ihl = (f[14] & 15) * 4
        let total = u16(f, 16)
        if ihl < 20 or total < ihl or total > n:
            return nil
        if csum(f, 14, ihl, 0) != 0:
            self.drops += 1
            return nil
        if (u16(f, 20) & 0x3FFF) != 0:      # a fragment (or MF set): not supported
            self.drops += 1
            return nil
        let proto = f[23]
        let src = u32(f, 26)
        let dst = u32(f, 30)
        if not (dst == self.ip or self.is_bcast(dst) or self.ip == 0):
            return nil
        let body = f.slice(14 + ihl, 14 + total)
        if proto == 1:
            self.icmp_in(src, body)
        elif proto == 17:
            self.udp_in(src, dst, body)
        elif proto == 6:
            self.tcp_in(src, dst, body)

    # ---- ICMP ----
    func icmp_in(self, src, b):
        if len(b) < 8 or csum(b, 0, len(b), 0) != 0:
            return nil
        if b[0] == 8:
            let r = b.copy()
            r[0] = 0
            put16(r, 2, 0)
            put16(r, 2, csum(r, 0, len(r), 0))
            self.ip_send(1, src, r)
        elif b[0] == 0:
            self.pings[u16(b, 4) * 65536 + u16(b, 6)] = self.clock()

    # one echo request: the round trip in ms, or -1 when there is no answer
    func ping(self, dst, timeout = 2000, size = 32):
        self.ping_seq = (self.ping_seq + 1) & 0xFFFF
        let id = 0x5350
        let key = id * 65536 + self.ping_seq
        let m = [8, 0, 0, 0]
        p16(m, id)
        p16(m, self.ping_seq)
        for i in range(size):
            m.append(i & 255)
        put16(m, 2, csum(m, 0, len(m), 0))
        let t0 = self.clock()
        if not self.ip_send(1, dst, m):
            return -1
        let ok = self.run_until(() => self.pings[key] != nil, timeout)
        if not ok:
            return -1
        let t1 = self.pings[key]
        self.pings[key] = nil
        return t1 - t0

    # ---- UDP ----
    func udp_open(self, port = 0):
        let p = port
        if p == 0:
            p = self.alloc_port()
        let s = UdpSocket(p)
        self.udp[p] = s
        return s

    func udp_close(self, s):
        self.udp[s.port] = nil

    func alloc_port(self):
        while true:
            let p = self.next_port
            self.next_port = self.next_port + 1
            if self.next_port > 65000:
                self.next_port = 49152
            if self.udp[p] == nil and self.listeners[p] == nil:
                return p

    func udp_send(self, s, dst, dport, data, src = nil):
        let u = []
        p16(u, s.port)
        p16(u, dport)
        p16(u, 8 + len(data))
        p16(u, 0)
        u.extend(data)
        let sa = self.ip if src == nil else src
        let c = csum(u, 0, len(u), pseudo_sum(sa, dst, 17, len(u)))
        put16(u, 6, 0xFFFF if c == 0 else c)
        return self.ip_send(17, dst, u, src)

    func udp_in(self, src, dst, b):
        if len(b) < 8:
            return nil
        let n = u16(b, 4)
        if n < 8 or n > len(b):
            return nil
        if u16(b, 6) != 0 and csum(b, 0, n, pseudo_sum(src, dst, 17, n)) != 0:
            self.drops += 1
            return nil
        let s = self.udp[u16(b, 2)]
        if s == nil:
            return nil
        if len(s.queue) < 64:
            s.queue.append([src, u16(b, 0), b.slice(8, n)])

    # the next datagram [source address, source port, bytes], waiting up to ms; nil if none
    func udp_recv(self, s, ms):
        let ok = self.run_until(() => len(s.queue) > 0, ms)
        if not ok:
            return nil
        return s.queue.remove_at(0)

    # ---- DHCP ----
    func dhcp_msg(self, mtype, xid, extra):
        let m = [1, 1, 6, 0]
        p32(m, xid)
        p16(m, 0)
        p16(m, 0x8000)                       # broadcast flag: the reply may arrive before we have an address
        for i in range(16):
            m.append(0)
        m.extend(self.mac)
        for i in range(10 + 64 + 128):
            m.append(0)
        p32(m, 0x63825363)
        m.extend([53, 1, mtype])
        m.extend([61, 7, 1])
        m.extend(self.mac)
        m.extend([12, 6, 115, 112, 114, 105, 110, 116])   # host name "sprint"
        m.extend([55, 4, 1, 3, 6, 51])       # asks for: mask, router, DNS, lease time
        m.extend(extra)
        m.append(255)
        return m

    func dhcp_parse(self, d, xid):
        if len(d) < 240 or d[0] != 2 or u32(d, 4) != xid or u32(d, 236) != 0x63825363:
            return nil
        if not same(d.slice(28, 34), self.mac):
            return nil
        let r = {yiaddr: u32(d, 16), type: 0, mask: 0, router: 0, dns: 0, server: 0, lease: 0}
        let i = 240
        while i < len(d):
            let o = d[i]
            if o == 255:
                break
            if o == 0:
                i += 1
                continue
            if i + 1 >= len(d):
                break
            let l = d[i + 1]
            let v = i + 2
            if v + l > len(d):
                break
            if o == 53:
                r.type = d[v]
            elif o == 1 and l >= 4:
                r.mask = u32(d, v)
            elif o == 3 and l >= 4:
                r.router = u32(d, v)
            elif o == 6 and l >= 4:
                r.dns = u32(d, v)
            elif o == 54 and l >= 4:
                r.server = u32(d, v)
            elif o == 51 and l >= 4:
                r.lease = u32(d, v)
            i = v + l
        return r

    # wait for a DHCP message of the type (2 offer, 5 ack) for xid
    func dhcp_wait(self, s, xid, mtype, ms):
        let t0 = self.clock()
        while true:
            let left = ms - (self.clock() - t0)
            if left <= 0:
                return nil
            let r = self.udp_recv(s, left)
            if r == nil:
                return nil
            let p = self.dhcp_parse(r[2], xid)
            if p != nil and p.type == mtype:
                return p

    # get an address, mask, gateway and DNS server from a DHCP server; returns true when configured
    func dhcp(self, timeout = 8000):
        let s = self.udp_open(68)
        let saved = self.ip
        self.ip = 0
        let xid = (self.clock() * 2654435761 + 12345) & MASK32
        let result = false
        for attempt in range(4):
            self.udp_send(s, MASK32, 67, self.dhcp_msg(1, xid, []), 0)
            let offer = self.dhcp_wait(s, xid, 2, timeout >> 2)
            if offer == nil:
                continue
            let extra = [50, 4]
            p32(extra, offer.yiaddr)
            extra.extend([54, 4])
            p32(extra, offer.server)
            self.udp_send(s, MASK32, 67, self.dhcp_msg(3, xid, extra), 0)
            let ack = self.dhcp_wait(s, xid, 5, timeout >> 2)
            if ack == nil:
                continue
            self.ip = ack.yiaddr
            self.mask = ack.mask if ack.mask != 0 else offer.mask
            self.gw = ack.router if ack.router != 0 else offer.router
            self.dns = ack.dns if ack.dns != 0 else offer.dns
            self.lease = ack.lease
            result = true
            break
        if not result:
            self.ip = saved
        self.udp_close(s)
        return result

    # ---- DNS ----
    func dns_name(self, name):
        let q = []
        for label in name.split("."):
            if len(label) == 0 or len(label) > 63:
                return nil
            q.append(len(label))
            q.extend(str.to_bytes(label))
        q.append(0)
        return q

    # skip a name at offset o of d: returns the offset after it
    func dns_skip(self, d, o):
        while o < len(d):
            let l = d[o]
            if l == 0:
                return o + 1
            if (l & 0xC0) == 0xC0:
                return o + 2
            o += l + 1
        return len(d)

    # the A record of a name as an int (nil if it does not resolve); answers are cached for their TTL (at most 5 minutes)
    func resolve(self, name, timeout = 4000):
        let a = ip(name)
        if a != nil:
            return a
        let key = name.lower()
        let c = self.dns_cache[key]
        if c != nil and c[1] > self.clock():
            return c[0]
        if self.dns == 0:
            return nil
        let qn = self.dns_name(key)
        if qn == nil:
            return nil
        let s = self.udp_open(0)
        let result = nil
        for attempt in range(3):
            self.dns_id = (self.dns_id + 1) & 0xFFFF
            let id = self.dns_id
            let q = []
            p16(q, id)
            p16(q, 0x0100)
            p16(q, 1)
            p16(q, 0)
            p16(q, 0)
            p16(q, 0)
            q.extend(qn)
            p16(q, 1)
            p16(q, 1)
            self.udp_send(s, self.dns, self.dns_port, q)
            let t0 = self.clock()
            let wait = timeout / 3
            while self.clock() - t0 < wait:
                let r = self.udp_recv(s, wait - (self.clock() - t0))
                if r == nil:
                    break
                let d = r[2]
                if len(d) < 12 or u16(d, 0) != id or (d[2] & 0x80) == 0:
                    continue
                if (d[3] & 15) != 0:
                    self.udp_close(s)
                    return nil
                let qd = u16(d, 4)
                let an = u16(d, 6)
                let o = 12
                for i in range(qd):
                    o = self.dns_skip(d, o) + 4
                for i in range(an):
                    o = self.dns_skip(d, o)
                    if o + 10 > len(d):
                        break
                    let ty = u16(d, o)
                    let ttl = u32(d, o + 4)
                    let rl = u16(d, o + 8)
                    o += 10
                    if ty == 1 and rl == 4 and o + 4 <= len(d):
                        result = u32(d, o)
                        let life = ttl if ttl < 300 else 300
                        self.dns_cache[key] = [result, self.clock() + life * 1000]
                        break
                    o += rl
                if result != nil:
                    break
            if result != nil:
                break
        self.udp_close(s)
        return result

    # ---- TCP ----
    func conn_key(self, lport, rip, rport):
        return to_string(lport) .. ":" .. to_string(rip) .. ":" .. to_string(rport)

    func new_isn(self):
        self.isn_n = (self.isn_n + 64009 + self.clock() * 250) & MASK32
        return self.isn_n

    # one segment of c: seq / flags / payload
    func tcp_xmit(self, c, seq, flags, data):
        let h = []
        p16(h, c.lport)
        p16(h, c.rport)
        p32(h, seq)
        p32(h, c.rcv_nxt if (flags & F_ACK) != 0 else 0)
        let hl = 6 if (flags & F_SYN) != 0 else 5
        h.append(hl << 4)
        h.append(flags)
        let w = RECV_LIMIT - len(c.rbuf)
        p16(h, w if w > 0 else 0)
        p16(h, 0)
        p16(h, 0)
        if (flags & F_SYN) != 0:
            h.extend([2, 4, 0x05, 0xB4])           # MSS 1460
        h.extend(data)
        put16(h, 16, csum(h, 0, len(h), pseudo_sum(self.ip, c.rip, 6, len(h))))
        self.ip_send(6, c.rip, h)

    func tcp_reset(self, src, dst, sport, dport, seq, ack, flags):
        let h = []
        p16(h, dport)
        p16(h, sport)
        let rf = F_RST
        let sn = 0
        let an = 0
        if (flags & F_ACK) != 0:
            sn = ack
        else:
            rf = F_RST | F_ACK
            an = (seq + 1) & MASK32
        p32(h, sn)
        p32(h, an)
        h.append(5 << 4)
        h.append(rf)
        p16(h, 0)
        p16(h, 0)
        p16(h, 0)
        put16(h, 16, csum(h, 0, len(h), pseudo_sum(dst, src, 6, len(h))))
        self.ip_send(6, src, h)

    func tcp_ack(self, c):
        self.tcp_xmit(c, c.snd_nxt, F_ACK, [])

    # send whatever the window allows: data, then the FIN once all the data is out
    func tcp_output(self, c):
        if c.state == "CLOSED" or c.state == "SYN_SENT" or c.state == "SYN_RCVD" or c.state == "LISTEN":
            return nil
        let inflight = (c.snd_nxt - c.snd_una) & MASK32
        if c.fin_sent and not c.fin_acked:
            pass
        let off = inflight
        if off > len(c.sbuf):
            off = len(c.sbuf)
        let wnd = c.snd_wnd if c.snd_wnd < WINDOW_CAP else WINDOW_CAP
        while off < len(c.sbuf) and (off < wnd or (wnd == 0 and off == 0)):
            let n = len(c.sbuf) - off
            if n > c.mss:
                n = c.mss
            if wnd > 0 and n > wnd - off:
                n = wnd - off
            if n <= 0:
                break
            let seq = (c.snd_una + off) & MASK32
            self.tcp_xmit(c, seq, F_ACK | F_PSH, c.sbuf.slice(off, off + n))
            off += n
            let nx = (c.snd_una + off) & MASK32
            if seq_lt(c.snd_nxt, nx):
                c.snd_nxt = nx
        if c.fin_pending and not c.fin_sent and off == len(c.sbuf) and not c.fin_acked:
            c.fin_seq = (c.snd_una + len(c.sbuf)) & MASK32
            self.tcp_xmit(c, c.fin_seq, F_FIN | F_ACK, [])
            c.fin_sent = true
            c.snd_nxt = (c.fin_seq + 1) & MASK32
            if c.state == "ESTABLISHED":
                c.state = "FIN_WAIT_1"
            elif c.state == "CLOSE_WAIT":
                c.state = "LAST_ACK"
        if c.snd_nxt != c.snd_una and c.rto_at == 0:
            c.rto_at = self.clock() + c.rto

    func tcp_connect(self, dst, port, timeout = 5000):
        let c = Conn()
        c.lport = self.alloc_port()
        c.rip = dst
        c.rport = port
        c.iss = self.new_isn()
        c.snd_una = c.iss
        c.snd_nxt = (c.iss + 1) & MASK32
        c.state = "SYN_SENT"
        self.conns[self.conn_key(c.lport, dst, port)] = c
        if self.ip != 0 and self.mac_for(dst) == nil:
            self.conns[self.conn_key(c.lport, dst, port)] = nil
            return nil
        self.tcp_xmit(c, c.iss, F_SYN, [])
        c.rto_at = self.clock() + c.rto
        let ok = self.run_until(() => c.state != "SYN_SENT", timeout)
        if not ok or c.state != "ESTABLISHED":
            self.conns[self.conn_key(c.lport, dst, port)] = nil
            c.state = "CLOSED"
            return nil
        return c

    func tcp_listen(self, port):
        let l = Listener(port)
        self.listeners[port] = l
        return l

    func tcp_unlisten(self, l):
        self.listeners[l.port] = nil

    func tcp_accept(self, l, ms):
        let ok = self.run_until(() => len(l.queue) > 0, ms)
        if not ok:
            return nil
        return l.queue.remove_at(0)

    # queue data to send; waits only while the send buffer is full. Use tcp_flush to wait until the peer has acknowledged it.
    func tcp_send(self, c, data):
        if c.err != nil:
            fail("ECONNRESET", c.err)
        if c.state != "ESTABLISHED" and c.state != "CLOSE_WAIT":
            fail("EPIPE", "connection not open for writing")
        let pos = 0
        while pos < len(data):
            if len(c.sbuf) >= SEND_LIMIT:
                let ok = self.run_until(() => len(c.sbuf) < SEND_LIMIT or c.state == "CLOSED", 10000)
                if not ok or c.state == "CLOSED":
                    fail("ETIMEDOUT", "send timed out")
            let n = SEND_LIMIT - len(c.sbuf)
            if n > len(data) - pos:
                n = len(data) - pos
            c.sbuf.extend(data.slice(pos, pos + n))
            pos += n
            self.tcp_output(c)
        return len(data)

    func tcp_flush(self, c, ms = 10000):
        return self.run_until(() => len(c.sbuf) == 0 or c.state == "CLOSED", ms)

    # up to max bytes; [] at the end of the stream, nil when nothing arrived within ms
    func tcp_recv(self, c, max, ms):
        let ok = self.run_until(() => len(c.rbuf) > 0 or c.fin_rcvd or c.state == "CLOSED" or c.err != nil, ms)
        if len(c.rbuf) > 0:
            let n = max if max < len(c.rbuf) else len(c.rbuf)
            let out = c.rbuf.slice(0, n)
            c.rbuf = c.rbuf.slice(n)
            if len(c.rbuf) + n >= RECV_LIMIT - 2 * MSS_DEFAULT:
                self.tcp_ack(c)               # the window opened again
            return out
        if c.err != nil:
            fail("ECONNRESET", c.err)
        if c.fin_rcvd or c.state == "CLOSED":
            return []
        return nil

    # close our side: sends the data still queued, then a FIN, and waits until the FIN is acknowledged (or ms pass)
    func tcp_close(self, c, ms = 3000):
        if c.state == "CLOSED" or c.state == "SYN_SENT":
            c.state = "CLOSED"
            self.conns[self.conn_key(c.lport, c.rip, c.rport)] = nil
            return true
        if c.state == "SYN_RCVD":
            c.state = "CLOSED"
            self.conns[self.conn_key(c.lport, c.rip, c.rport)] = nil
            return true
        c.fin_pending = true
        self.tcp_output(c)
        return self.run_until(() => c.fin_acked or c.state == "CLOSED", ms)

    func tcp_abort(self, c):
        if c.state != "CLOSED" and c.state != "SYN_SENT":
            self.tcp_xmit(c, c.snd_nxt, F_RST | F_ACK, [])
        c.state = "CLOSED"
        self.conns[self.conn_key(c.lport, c.rip, c.rport)] = nil

    func tcp_drop(self, c, why):
        c.err = why
        c.state = "CLOSED"
        self.conns[self.conn_key(c.lport, c.rip, c.rport)] = nil

    func tcp_in(self, src, dst, b):
        if len(b) < 20:
            return nil
        if csum(b, 0, len(b), pseudo_sum(src, dst, 6, len(b))) != 0:
            self.drops += 1
            return nil
        let sport = u16(b, 0)
        let dport = u16(b, 2)
        let seq = u32(b, 4)
        let ack = u32(b, 8)
        let off = (b[12] >> 4) * 4
        let flags = b[13]
        let wnd = u16(b, 14)
        if off < 20 or off > len(b):
            return nil
        let data = b.slice(off)
        let c = self.conns[self.conn_key(dport, src, sport)]
        if c == nil:
            let l = self.listeners[dport]
            if l != nil and (flags & F_SYN) != 0 and (flags & (F_ACK | F_RST)) == 0:
                self.tcp_syn_in(l, src, sport, dport, seq, b, off, wnd)
            elif (flags & F_RST) == 0:
                self.tcp_reset(src, dst, sport, dport, seq + len(data) + (1 if (flags & (F_SYN | F_FIN)) != 0 else 0), ack, flags)
            return nil
        if c.state == "SYN_SENT":
            if (flags & F_ACK) != 0 and ack != ((c.iss + 1) & MASK32):
                if (flags & F_RST) == 0:
                    self.tcp_reset(src, dst, sport, dport, seq, ack, flags)
                return nil
            if (flags & F_RST) != 0:
                if (flags & F_ACK) != 0:
                    self.tcp_drop(c, "connection refused")
                return nil
            if (flags & F_SYN) != 0:
                c.irs = seq
                c.rcv_nxt = (seq + 1) & MASK32
                c.snd_wnd = wnd
                c.mss = self.tcp_mss(b, off)
                if (flags & F_ACK) != 0:
                    c.snd_una = ack
                    c.state = "ESTABLISHED"
                    c.rto_at = 0
                    c.retries = 0
                    c.rto = 300
                    self.tcp_ack(c)
                else:
                    c.state = "SYN_RCVD"
                    self.tcp_xmit(c, c.iss, F_SYN | F_ACK, [])
            return nil
        # synchronized states
        if (flags & F_RST) != 0:
            if c.state == "TIME_WAIT":
                return nil
            self.tcp_drop(c, "connection reset by peer")
            return nil
        if (flags & F_SYN) != 0:
            if c.state == "SYN_RCVD" and seq == c.irs:
                self.tcp_xmit(c, c.iss, F_SYN | F_ACK, [])
            else:
                self.tcp_ack(c)
            return nil
        if (flags & F_ACK) == 0:
            return nil
        if c.state == "SYN_RCVD":
            if ack == ((c.iss + 1) & MASK32):
                c.snd_una = ack
                c.snd_wnd = wnd
                c.state = "ESTABLISHED"
                c.rto_at = 0
                c.retries = 0
                c.rto = 300
                if c.listener != nil:
                    if len(c.listener.queue) < 16:
                        c.listener.queue.append(c)
                    else:
                        self.tcp_abort(c)
                        return nil
            else:
                self.tcp_reset(src, dst, sport, dport, seq, ack, flags)
                return nil
        # acknowledgements
        if seq_le(c.snd_una, ack) and seq_le(ack, c.snd_nxt):
            let adv = (ack - c.snd_una) & MASK32
            if adv > 0:
                let nd = adv if adv < len(c.sbuf) else len(c.sbuf)
                if nd > 0:
                    c.sbuf = c.sbuf.slice(nd)
                c.snd_una = ack
                c.retries = 0
                c.rto = 300
                c.rto_at = 0 if c.snd_una == c.snd_nxt else self.clock() + c.rto
                if c.fin_sent and ack == ((c.fin_seq + 1) & MASK32):
                    c.fin_acked = true
                    if c.state == "FIN_WAIT_1":
                        c.state = "FIN_WAIT_2"
                    elif c.state == "CLOSING":
                        c.state = "TIME_WAIT"
                        c.tw_at = self.clock() + 1000
                    elif c.state == "LAST_ACK":
                        c.state = "CLOSED"
                        self.conns[self.conn_key(c.lport, c.rip, c.rport)] = nil
            c.snd_wnd = wnd
        if c.state == "CLOSED":
            return nil
        # data
        let need_ack = false
        let has_fin = (flags & F_FIN) != 0
        if len(data) > 0 or has_fin:
            if c.state == "ESTABLISHED" or c.state == "FIN_WAIT_1" or c.state == "FIN_WAIT_2":
                let skip = 0
                if seq_lt(seq, c.rcv_nxt):
                    skip = (c.rcv_nxt - seq) & MASK32
                    need_ack = true
                if skip <= len(data) and (skip == 0 or skip < len(data) or has_fin) and (seq == c.rcv_nxt or skip > 0):
                    let room = RECV_LIMIT - len(c.rbuf)
                    let take = len(data) - skip
                    if take > room:
                        take = room
                        has_fin = false
                    if take > 0:
                        c.rbuf.extend(data.slice(skip, skip + take))
                        c.rcv_nxt = (c.rcv_nxt + take) & MASK32
                    need_ack = true
                    let end_seq = (seq + len(data)) & MASK32
                    if has_fin and end_seq == c.rcv_nxt and not c.fin_rcvd:
                        c.rcv_nxt = (c.rcv_nxt + 1) & MASK32
                        c.fin_rcvd = true
                        if c.state == "ESTABLISHED":
                            c.state = "CLOSE_WAIT"
                        elif c.state == "FIN_WAIT_1":
                            c.state = "CLOSING"
                        elif c.state == "FIN_WAIT_2":
                            c.state = "TIME_WAIT"
                            c.tw_at = self.clock() + 1000
                else:
                    need_ack = true            # out of order or outside the window: the ACK tells the peer where we are
            elif c.state == "CLOSE_WAIT" or c.state == "CLOSING" or c.state == "LAST_ACK" or c.state == "TIME_WAIT":
                need_ack = true
        if need_ack:
            self.tcp_ack(c)
        self.tcp_output(c)

    func tcp_mss(self, b, off):
        let m = 536
        let i = 20
        while i < off:
            let k = b[i]
            if k == 0:
                break
            if k == 1:
                i += 1
                continue
            if i + 1 >= off or b[i + 1] < 2:
                break
            if k == 2 and b[i + 1] == 4 and i + 3 < off:
                m = u16(b, i + 2)
            i += b[i + 1]
        return m if m < MSS_DEFAULT else MSS_DEFAULT

    func tcp_syn_in(self, l, src, sport, dport, seq, b, off, wnd):
        let c = Conn()
        c.lport = dport
        c.rip = src
        c.rport = sport
        c.irs = seq
        c.rcv_nxt = (seq + 1) & MASK32
        c.iss = self.new_isn()
        c.snd_una = c.iss
        c.snd_nxt = (c.iss + 1) & MASK32
        c.snd_wnd = wnd
        c.mss = self.tcp_mss(b, off)
        c.state = "SYN_RCVD"
        c.listener = l
        self.conns[self.conn_key(dport, src, sport)] = c
        self.tcp_xmit(c, c.iss, F_SYN | F_ACK, [])
        c.rto_at = self.clock() + c.rto

    # ---- timers: retransmission and the end of TIME_WAIT ----
    func timers(self):
        let now = self.clock()
        let dead = []
        for k in self.conns:
            let c = self.conns[k]
            if c.state == "TIME_WAIT" and c.tw_at <= now:
                dead.append(k)
                c.state = "CLOSED"
                continue
            if c.rto_at != 0 and c.rto_at <= now and c.state != "CLOSED":
                c.retries += 1
                if c.retries > 8:
                    dead.append(k)
                    c.err = "timed out"
                    c.state = "CLOSED"
                    continue
                c.rto = c.rto * 2 if c.rto < 4000 else 4000
                c.rto_at = now + c.rto
                if c.state == "SYN_SENT":
                    self.tcp_xmit(c, c.iss, F_SYN, [])
                elif c.state == "SYN_RCVD":
                    self.tcp_xmit(c, c.iss, F_SYN | F_ACK, [])
                else:
                    c.snd_nxt = c.snd_una              # go back and send the window again
                    if c.fin_sent and not c.fin_acked:
                        c.fin_sent = false
                        c.fin_pending = true
                    self.tcp_output(c)
                    c.rto_at = now + c.rto
        for k in dead:
            self.conns[k] = nil
