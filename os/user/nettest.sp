# nettest: starts the network card driver and the TCP/IP stack and uses them against QEMU's user-mode network: DHCP, ping of the gateway, DNS, a UDP echo,
# a TCP client transfer, and a TCP server (QEMU forwards a host port to guest port 7000). The QEMU test os-net-test runs this as the init program
# and plays the host side (os/tests/net_test.py).
import psys as sys
import ipc
import netstack
import netlink
import str
import io
import sslcore
import sprintssl
import urtc
import testroots

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

    # TLS 1.3 against python's ssl module on the host: an ECDSA leaf under an ECDSA intermediate, an RSA leaf (RSA-PSS signature), an Ed25519 leaf
    sslcore.seed(sslcore.from_str(to_string(sys.ms()) .. netstack.mac_str(link.mac)))
    let now = nil
    try:
        now = sprintssl.unix_time(urtc.now())
    catch e:
        now = nil
    say("nettest: tls clock", "none" if now == nil else to_string(now))
    let roots = sprintssl.load_roots(testroots.INTEROP_ROOT)
    let others = sprintssl.load_roots(testroots.OTHER_ROOT)
    let names = ["ec", "rsa", "ed"]
    for i in range(3):
        let tc = st.tcp_connect(host, 18443 + i, 5000)
        if tc == nil:
            say("nettest: tls", names[i], "tcp connect failed")
            continue
        let tt = sprintssl.TcpTransport(st, tc)
        try:
            let t2 = sys.ms()
            let conn = sprintssl.connect(tt, "interop.test", roots, now)
            let r = sprintssl.http_get(conn, "interop.test", "/hello")
            say("nettest: tls", names[i], conn.suite.name, "status", r.status, "body", sslcore.to_str(r.body), "in", sys.ms() - t2, "ms")
            if i == 0:
                let big = sprintssl.http_get(conn, "interop.test", "/big")
                say("nettest: tls big", len(big.body), "bytes")
            conn.close()
        catch e:
            say("nettest: tls", names[i], "failed:", to_string(e))
        st.tcp_close(tc)
    # GitHub Pages: the host relays port 18500 to octocat.github.io:443 through the proxy (a plain TCP tunnel, so the TLS session is between the guest and GitHub)
    let tg = st.tcp_connect(host, 18500, 5000)
    if tg != nil:
        try:
            let t3 = sys.ms()
            let gh = sprintssl.connect(sprintssl.TcpTransport(st, tg), "octocat.github.io", sprintssl.load_roots(testroots.ISRG_ROOT_X1), now, ["http/1.1"])
            let gr = sprintssl.http_get(gh, "octocat.github.io", "/")
            say("nettest: github.io", gh.suite.name, "status", gr.status, "body", to_string(len(gr.body)) .. " bytes, server " .. to_string(gr.headers["server"]), "in", sys.ms() - t3, "ms")
            gh.close()
        catch e:
            say("nettest: github.io failed:", to_string(e))
        st.tcp_close(tg)
    let tc2 = st.tcp_connect(host, 18443, 5000)
    let tt2 = sprintssl.TcpTransport(st, tc2)
    try:
        let conn2 = sprintssl.connect(tt2, "interop.test", others, now)
        say("nettest: tls wrong root: accepted (BAD)")
    catch e:
        say("nettest: tls wrong root refused:", to_string(e))
    st.tcp_close(tc2)

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
