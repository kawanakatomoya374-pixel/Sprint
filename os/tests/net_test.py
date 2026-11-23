#!/usr/bin/env python3
"""The network card as a user-space, interrupt-driven server. Boot a SprintOS image (init=nettest) on QEMU with an Intel E1000 (and, second, an E1000E) on the
user-mode network: netd (ring 3) maps the card's registers, sets up the DMA rings, finds which interrupt input the card raises, and gets an ARP reply for
the gateway 10.0.2.2 - all from interrupts."""
import os, subprocess, sys
IMG = sys.argv[1]
OUT = os.path.join(os.path.dirname(IMG), "shots")
os.makedirs(OUT, exist_ok=True)
fails = []
def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c: fails.append(what)
for model in ("e1000", "e1000e"):
    ser = os.path.join(OUT, "net-%s.log" % model)
    if os.path.exists(ser): os.remove(ser)
    try:
        subprocess.run(["qemu-system-x86_64", "-m", "256", "-smp", "2", "-drive", "format=raw,file=" + IMG, "-netdev", "user,id=n0", "-device", model + ",netdev=n0",
                        "-display", "none", "-no-reboot", "-serial", "file:" + ser, "-device", "isa-debug-exit,iobase=0xf4,iosize=4"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    except subprocess.TimeoutExpired:
        pass
    L = open(ser, errors="replace").read()
    check("[netd] found device 8086:" in L and "link up" in L, "[%s] netd found the card, read its MAC and the link is up" % model)
    check("[netd] interrupt works: card input" in L, "[%s] the card's interrupt reaches the driver (I/O APIC -> kernel -> message), no polling" % model)
    check("[netd] ARP reply: 10.0.2.2 is at" in L, "[%s] a frame was sent and the reply received through the receive interrupt" % model)
    check("nettest: done" in L, "[%s] the driver quits on request" % model)
sys.exit(1 if fails else 0)
