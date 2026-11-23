# nettest: starts the network card driver and the TCP/IP stack and uses them against QEMU's user-mode network: DHCP, ping of the gateway, DNS, a UDP echo,
# a TCP client transfer, and a TCP server (QEMU forwards a host port to guest port 7000). The QEMU test os-net-test runs this as the init program
# and plays the host side (os/tests/net_test.py).
import psys as sys
import ipc
import netstack
import netlink
import str
import io

const HOST = "10.0.2.2"

# (serial output is buffered: flush after every line so the host side of the test can follow along)
func say(a, b = "", c = "", d = "", e = "", f = "", g = "", h = "", i = "", j = "", k = ""):
    let parts = [a, b, c, d, e, f, g, h, i, j, k].filter(x => x != "")
    print(parts.map(x => to_string(x)).join(" "))
    io.flush()
const TCP_PORT = 18080
const UDP_PORT = 18081
const LISTEN_PORT = 7000

func fnv(a):
    let h = 2166136261
    for x in a:
        h = ((h ^ x) * 16777619) & 0xFFFFFFFF
    return h

func upper(a):
    return a.map(x => x - 32 if x >= 97 and x <= 122 else x)

let n = sys.spawn("netd")
let link = netlink.Link()
say("nettest: link up, MAC", netstack.mac_str(link.mac))
let st = netstack.Stack(link, sys.ms, link.mac)
let t0 = sys.ms()
let got = st.dhcp()
say("nettest: dhcp", got, netstack.ip_str(st.ip), netstack.ip_str(st.mask), "gw", netstack.ip_str(st.gw), "dns", netstack.ip_str(st.dns), "in", sys.ms() - t0, "ms")
if got:
    let host = netstack.ip(HOST)
    let rtt = st.ping(host, 2000)
    say("nettest: ping gateway", "ok" if rtt >= 0 else "failed")
    let name = st.resolve("localhost")                  # QEMU's own resolver (it forwards to the host's, which may not exist: only reported)
    say("nettest: dns localhost (QEMU resolver)", netstack.ip_str(name) if name != nil else "none")
    let real_dns = st.dns
    st.dns = host                                       # a DNS server on the host (UDP port 18053)
    st.dns_port = 18053
    let name2 = st.resolve("sprint.test")
    say("nettest: dns sprint.test", netstack.ip_str(name2) if name2 != nil else "none")
    st.dns = real_dns
    st.dns_port = 53
    let s = st.udp_open(0)
    st.udp_send(s, host, UDP_PORT, str.to_bytes("hello udp"))
    let r = st.udp_recv(s, 3000)
    say("nettest: udp echo", str.from_bytes(r[2]) if r != nil else "none")
    st.udp_close(s)

    let c = st.tcp_connect(host, TCP_PORT, 5000)
    if c == nil:
        say("nettest: tcp connect failed")
    else:
        let data = []
        for i in range(40000):
            data.append(97 + (i * 5 + (i >> 7)) % 26)
        let t1 = sys.ms()
        st.tcp_send(c, data)
        let back = []
        while len(back) < len(data):
            let p = st.tcp_recv(c, 4096, 5000)
            if p == nil or len(p) == 0:
                break
            back.extend(p)
        say("nettest: tcp client", len(back), "bytes back, match", fnv(back) == fnv(upper(data)), "in", sys.ms() - t1, "ms")
        st.tcp_close(c)

    let l = st.tcp_listen(LISTEN_PORT)
    say("nettest: listening", LISTEN_PORT)
    let sc = st.tcp_accept(l, 20000)
    if sc == nil:
        say("nettest: nobody connected")
    else:
        let buf = []
        while true:
            let p = st.tcp_recv(sc, 4096, 5000)
            if p == nil or len(p) == 0:
                break
            buf.extend(p)
        say("nettest: tcp server got", len(buf), "bytes")
        st.tcp_send(sc, upper(buf))
        st.tcp_close(sc)
        say("nettest: tcp server done")
    say("nettest: stack", st.rx_count, "frames in,", st.tx_count, "out,", st.drops, "dropped")
link.close()
ipc.send(ipc.lookup("net"), "quit")
sys.wait(n)
say("nettest: done")
