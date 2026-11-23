#!/usr/bin/env python3
"""The GPU as a user-space server. Boot a SprintOS image (init=gputest) on QEMU with a virtio-vga device: gpud (ring 3) finds it on the PCI bus, maps
its registers, sets up the virtqueues in DMA memory, creates a 2D resource and points the scanout at it. gputest fills the screen with four colour bands
through the shared pixel memory and asks gpud to flush; the test takes QEMU's screendump of the virtio scanout and checks the pixels."""
import os, socket, subprocess, sys, time
IMG = sys.argv[1]
OUT = os.path.join(os.path.dirname(IMG), "shots")
os.makedirs(OUT, exist_ok=True)
ser, mon, shot = os.path.join(OUT, "gpu.log"), os.path.join(OUT, "gpumon.sock"), os.path.join(OUT, "gpu.ppm")
for f in (ser, mon, shot):
    if os.path.exists(f): os.remove(f)
fails = []
def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c: fails.append(what)
q = subprocess.Popen(["qemu-system-x86_64", "-m", "256", "-smp", "2", "-drive", "format=raw,file=" + IMG, "-device", "virtio-vga", "-display", "none",
                      "-no-reboot", "-serial", "file:" + ser, "-monitor", "unix:" + mon + ",server,nowait"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        if os.path.exists(mon): break
        time.sleep(0.1)
    s = socket.socket(socket.AF_UNIX); s.connect(mon); time.sleep(0.5)
    log = lambda: open(ser, errors="replace").read()
    for _ in range(300):
        if "[gputest] drawn" in log() or "no gpu" in log(): break
        time.sleep(0.2)
    time.sleep(1)
    s.send(("screendump " + shot + "\n").encode()); time.sleep(1.5)
    L = log()
    check("[gpud] VirtIO-GPU ready" in L, "gpud (a user process) found the virtio-gpu, set up its queues and created the screen resource")
    check("[gputest] cursor image: ok" in L, "the hardware cursor image was accepted")
    check("[gputest] drawn" in L, "a client drew into the screen's shared pixel memory and flushed")
    d = open(shot, "rb").read()
    parts = d.split(b"\n", 3)
    w, h = map(int, parts[1].split()); px = parts[3]
    def at(x, y): i = 3 * (y * w + x); return tuple(px[i:i + 3])
    import re
    m = re.search(r"\[gputest\] screen (\d+)x(\d+)", L)
    check(m is not None and (w, h) == (int(m.group(1)), int(m.group(2))), "the virtio scanout is %dx%d, the size gpud reported" % (w, h))
    check(at(10, 10) == (255, 0, 0) and at(10, 300) == (0, 255, 0) and at(10, 500) == (0, 0, 255) and at(10, 700) == (255, 255, 0), "four colour bands are on the host's screen: " + str([at(10, y) for y in (10, 300, 500, 700)]))
    check(at(600, 120) == (255, 255, 255) and at(400, 120) == (255, 0, 0), "a partial flush updated just its rectangle")
finally:
    q.kill()

# ---- the whole desktop on the virtio GPU (sprintos.img, the normal boot) ----
DESK = sys.argv[2] if len(sys.argv) > 2 else None
if DESK:
    ser2, mon2, shot2 = os.path.join(OUT, "gpudesk.log"), os.path.join(OUT, "gpudeskmon.sock"), os.path.join(OUT, "gpudesk.ppm")
    for f in (ser2, mon2, shot2):
        if os.path.exists(f): os.remove(f)
    q = subprocess.Popen(["qemu-system-x86_64", "-m", "512", "-smp", "2", "-drive", "format=raw,file=" + DESK, "-vga", "none", "-device", "virtio-vga", "-display", "none",
                          "-no-reboot", "-serial", "file:" + ser2, "-monitor", "unix:" + mon2 + ",server,nowait"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if os.path.exists(mon2): break
            time.sleep(0.1)
        s = socket.socket(socket.AF_UNIX); s.connect(mon2); time.sleep(0.5)
        log2 = lambda: open(ser2, errors="replace").read()
        def c(x, t=0.15):
            s.send((x + "\n").encode()); time.sleep(t)
        for _ in range(400):
            if "[guid] ready" in log2(): break
            time.sleep(0.2)
        check("[guid] display: VirtIO-GPU through gpud" in log2() and "[guid] ready" in log2(), "the desktop (guid) draws through the GPU server instead of the kernel framebuffer")
        time.sleep(1)
        for _ in range(12): c("mouse_move -60 -45", 0.05)
        c("mouse_move 45 30", 0.3)
        for _ in range(2):
            c("mouse_button 1", 0.08); c("mouse_button 0", 0.08)
        time.sleep(2)
        check("[guid] open Terminal" in log2(), "input still works: a double-click opens the terminal")
        c("screendump " + shot2, 1.5)
        d = open(shot2, "rb").read()
        parts = d.split(b"\n", 3)
        w, h = map(int, parts[1].split()); px = parts[3]
        def at(x, y): i = 3 * (y * w + x); return tuple(px[i:i + 3])
        check(len(set(px[20::997])) > 20, "the host's screen shows the desktop (not blank)")
        check(at(300, 200) == (11, 14, 20) or sum(at(300, 200)) < 80, "the terminal window is on the host's screen at (300,200): %s" % (at(300, 200),))
    finally:
        q.kill()
sys.exit(1 if fails else 0)
