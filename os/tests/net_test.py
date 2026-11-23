#!/usr/bin/env python3
"""The network card (netd, ring 3, interrupt driven) and the TCP/IP stack written in Sprint, against QEMU's user-mode network. Boot a SprintOS image
(init=nettest) with an Intel E1000 (and, second, an E1000E): netd finds the card and the interrupt; the stack gets an address with DHCP, pings the gateway,
resolves a name with DNS, echoes a UDP datagram, runs a TCP client transfer against a server on the host (10.0.2.2) and serves one TCP connection
(QEMU forwards a host port to guest port 7000), all through netd's frame interface."""
import os, socket, subprocess, sys, threading, time
IMG = sys.argv[1]
OUT = os.path.join(os.path.dirname(IMG), "shots")
os.makedirs(OUT, exist_ok=True)
fails = []
def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c: fails.append(what)

TCP_PORT, UDP_PORT, FWD_PORT = 18080, 18081, 17000
def tcp_server(srv):
    while True:
        try: c, _ = srv.accept()
        except OSError: return
        def serve(c):
            try:
                while True:
                    d = c.recv(65536)
                    if not d: break
                    c.sendall(d.upper())
            finally: c.close()
        threading.Thread(target=serve, args=(c,), daemon=True).start()
def udp_server(u):
    while True:
        try: d, a = u.recvfrom(2048)
        except OSError: return
        u.sendto(d, a)

def dns_server(d):
    while True:
        try: q, a = d.recvfrom(512)
        except OSError: return
        o = 12
        while q[o]: o += q[o] + 1
        o += 5
        r = bytearray(q[:o]); r[2] = 0x81; r[3] = 0x80; r[7] = 1
        r += bytes([0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 7])
        d.sendto(bytes(r), a)

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", TCP_PORT)); srv.listen(4)
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(("127.0.0.1", UDP_PORT))
dd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); dd.bind(("127.0.0.1", 18053))
threading.Thread(target=tcp_server, args=(srv,), daemon=True).start()
threading.Thread(target=udp_server, args=(u,), daemon=True).start()
threading.Thread(target=dns_server, args=(dd,), daemon=True).start()

for model in ("e1000", "e1000e"):
    ser = os.path.join(OUT, "net-%s.log" % model)
    if os.path.exists(ser): os.remove(ser)
    q = subprocess.Popen(["qemu-system-x86_64", "-m", "256", "-smp", "2", "-drive", "format=raw,file=" + IMG,
                          "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:%d-:7000" % FWD_PORT, "-device", model + ",netdev=n0",
                          "-display", "none", "-no-reboot", "-serial", "file:" + ser, "-device", "isa-debug-exit,iobase=0xf4,iosize=4"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    reply = b""
    deadline = time.time() + 150
    connected = False
    while time.time() < deadline and q.poll() is None:
        L = open(ser, errors="replace").read() if os.path.exists(ser) else ""
        if "nettest: listening" in L and not connected:
            connected = True
            try:
                c = socket.create_connection(("127.0.0.1", FWD_PORT), timeout=10)
                c.sendall(b"hello from the host " * 50)
                c.shutdown(socket.SHUT_WR)
                c.settimeout(20)
                while True:
                    d = c.recv(4096)
                    if not d: break
                    reply += d
                c.close()
            except OSError as e:
                print("host side of the server test failed:", e)
        if "nettest: done" in L: break
        time.sleep(0.3)
    try: q.wait(timeout=5)
    except subprocess.TimeoutExpired: q.kill()
    L = open(ser, errors="replace").read()
    check("[netd] found device 8086:" in L and "link up" in L, "[%s] netd found the card, read its MAC and the link is up" % model)
    check("[netd] interrupt works: card input" in L, "[%s] the card's interrupt reaches the driver (I/O APIC -> kernel -> message), no polling" % model)
    check("[netd] ARP reply: 10.0.2.2 is at" in L, "[%s] a frame was sent and the reply received through the receive interrupt" % model)
    check("nettest: dhcp true 10.0.2.15 255.255.255.0 gw 10.0.2.2 dns 10.0.2.3" in L, "[%s] DHCP gives 10.0.2.15, gateway 10.0.2.2, DNS 10.0.2.3" % model)
    check("nettest: ping gateway ok" in L, "[%s] ICMP echo to the gateway is answered" % model)
    check("nettest: dns sprint.test 192.0.2.7" in L, "[%s] DNS: a name is resolved with a query to a DNS server on the host" % model)
    check("nettest: udp echo hello udp" in L, "[%s] a UDP datagram goes to the host and comes back" % model)
    check("nettest: tcp client 40000 bytes back, match true" in L, "[%s] TCP client: 40000 bytes to the host and the transformed bytes back, intact" % model)
    check("nettest: tcp server got 1000 bytes" in L and reply == (b"hello from the host " * 50).upper(), "[%s] TCP server: the host connects through QEMU's port forward, and gets its data back" % model)
    check("nettest: done" in L, "[%s] the stack and the driver shut down cleanly" % model)
sys.exit(1 if fails else 0)
