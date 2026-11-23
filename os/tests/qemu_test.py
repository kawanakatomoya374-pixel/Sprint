#!/usr/bin/env python3
"""Boot build/os/sprintos.iso in QEMU (no display) on 1 and on 2 processors and check the serial log: the Sprint
kernel starts ring-3 Sprint VMs, schedules them with timer preemption, sleeps/waits work, every physical page is
returned, and two processors finish the same CPU-bound jobs clearly sooner than one."""
import os, re, socket, subprocess, sys, time

ISO = sys.argv[1]
DESK = sys.argv[2] if len(sys.argv) > 2 else None
OUT = os.path.join(os.path.dirname(ISO), "shots")
os.makedirs(OUT, exist_ok=True)
fails = []
def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails.append(what)

def disk(path):
    """QEMU arguments that boot `path`: an ISO as a CD-ROM (GRUB), a raw .img as a hard disk (the Sprint BIOS bootloader), *uefi*.img (or SPRINT_FIRMWARE=uefi) under OVMF."""
    if "uefi" in os.path.basename(path) or os.environ.get("SPRINT_FIRMWARE") == "uefi":   # UEFI: OVMF firmware (SPRINT_OVMF), the image as a hard disk
        return ["-bios", os.environ.get("SPRINT_OVMF", "/usr/share/ovmf/OVMF.fd"), "-drive", "format=raw,file=" + path]
    return ["-drive", "format=raw,file=" + path] if path.endswith(".img") else ["-cdrom", path]

def boot(cpus):
    ser = os.path.join(OUT, "serial%d.log" % cpus)
    if os.path.exists(ser):
        os.remove(ser)
    try:
        subprocess.run(["qemu-system-x86_64", "-m", "256", "-smp", str(cpus)] + disk(ISO) + ["-display", "none", "-no-reboot",
                        "-serial", "file:" + ser, "-device", "isa-debug-exit,iobase=0xf4,iosize=4"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    except subprocess.TimeoutExpired:
        pass
    return open(ser, errors="replace").read()

times = {}
for cpus in (1, 2):
    log = boot(cpus)
    tag = "[%d cpu] " % cpus
    check("physical pages:" in log, tag + "kernel (Sprint) starts and owns physical memory")
    check("processors online: %d of %d" % (cpus, cpus) in log, tag + "all processors came online (ACPI MADT + INIT/SIPI, in Sprint)")
    check("init: started 2 3 4" in log and "init: sleeper 4 exited with 0" in log, tag + "ring-3 Sprint VMs run, sleep and exit")
    check(len(re.findall(r"worker \d ran \d+ rounds", log)) == 2, tag + "two CPU-bound workers both make progress (timer preemption)")
    check("init: ipc ready" in log and "ipckid: saw hello from init" in log, tag + "shared memory: a second process maps the creator's segment")
    check("shared write seen: kid!! 1234567890123" in log, tag + "shared memory is really shared (writes visible both ways)")
    check("200 round trips ok" in log and "answered 200 pings" in log, tag + "blocking messages between processes (200 round trips)")
    check("init: done" in log, tag + "init waited for all children")
    pages = [l.split(": ")[1] for l in log.splitlines() if l.startswith("[kernel] physical pages:")]
    free = [l.split(": ")[1] for l in log.splitlines() if l.startswith("[kernel] free pages after exit:")]
    check(bool(pages) and pages == free, tag + "all physical pages are returned at exit")
    m = re.search(r"init: 4 burners took (\d+) ms", log)
    times[cpus] = int(m.group(1)) if m else None
# the Sprint VMs (ring 0 and ring 3) run with the JIT: the interpreter alone needs ~7800 ms for these four jobs on one CPU (JIT: ~1800 ms)
check(bool(times[1]) and times[1] < 4500, "ring-3 Sprint code is JIT-compiled (4 burners on 1 CPU: %s ms, interpreter alone ~7800 ms)" % times[1])
check(all(times.values()) and times[2] < times[1] * 0.75,
      "2 processors finish 4 CPU-bound jobs sooner than 1 (%s ms vs %s ms)" % (times[2], times[1]))
def desktop():
    ser = os.path.join(OUT, "desktop.log")
    mon = os.path.join(OUT, "mon.sock")
    for f in (ser, mon):
        if os.path.exists(f):
            os.remove(f)
    # a second disk with a SprintFS volume (made on the host): the desktop's terminal reaches it through the file system server
    fsimg = os.path.join(OUT, "data.img")
    spx = os.environ.get("SPRINT", "build/sprint")
    hello = os.path.join(OUT, "hello.txt")
    open(hello, "w").write("hello from the data disk\n")
    for a in (["mkfs", "8"], ["put", hello, "/hello.txt"]):
        subprocess.run([spx, "run", "--allow-read=" + OUT, "--allow-write=" + OUT, "tools/sprintfs.sp", fsimg] + a, capture_output=True)
    q = subprocess.Popen(["qemu-system-x86_64", "-m", "512", "-smp", "2"] + disk(DESK) + ["-drive", "format=raw,file=" + fsimg + ",if=ide,index=1"] + ["-display", "none", "-no-reboot",
                          "-serial", "file:" + ser, "-monitor", "unix:" + mon + ",server,nowait"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if os.path.exists(mon):
                break
            time.sleep(0.1)
        s = socket.socket(socket.AF_UNIX)
        s.connect(mon)
        time.sleep(0.5)
        def c(x, t=0.15):
            s.send((x + "\n").encode())
            time.sleep(t)
        def log():
            return open(ser, errors="replace").read()
        for _ in range(400):
            if "[guid] ready" in log():
                break
            time.sleep(0.2)
        check("[guid] ready" in log(), "ring-3 desktop boots")
        c("screendump " + os.path.join(OUT, "d0.ppm"), 1)
        data = open(os.path.join(OUT, "d0.ppm"), "rb").read()
        check(len(set(data[20::997])) > 20, "desktop frame is not blank")
        for _ in range(12):
            c("mouse_move -60 -45", 0.05)
        c("mouse_move 45 30", 0.3)
        for _ in range(2):
            c("mouse_button 1", 0.08)
            c("mouse_button 0", 0.08)
        time.sleep(1.5)
        check("[guid] open Terminal" in log(), "mouse double-click opens an app")
        c("mouse_move 255 170", 0.3)
        c("mouse_button 1", 0.1)
        c("mouse_button 0", 0.3)
        for k in ("u", "n", "a", "m", "e", "ret"):
            c("sendkey " + k)
        time.sleep(1.5)
        check("[guid] $ uname => SprintOS" in log(), "keyboard input reaches the focused window")
        keys = {" ": "spc", "/": "slash", ".": "dot"}
        for ch in "dcat /hello.txt":
            c("sendkey " + keys.get(ch, ch), 0.12)
        c("sendkey ret", 0.3)
        time.sleep(3)
        check("[guid] $ dcat /hello.txt => hello from the data disk" in log(), "the terminal reads a file from the disk through the file system server (IPC)")
        # a window of another process: the Demo icon starts the program gdemo, which opens a window through the GUI server (messages + shared memory)
        c("mouse_move -255 245", 0.3)
        for _ in range(2):
            c("mouse_button 1", 0.08)
            c("mouse_button 0", 0.08)
        for _ in range(50):
            if "[gdemo] window open" in log():
                break
            time.sleep(0.2)
        check("[gdemo] window open" in log() and "of pid" in log(), "a client process opens a window through guid (IPC)")
        c("mouse_move 167 -280", 0.3)
        c("mouse_button 1", 0.1)
        c("mouse_button 0", 0.3)
        for k in ("a", "b"):
            c("sendkey " + k, 0.3)
        time.sleep(1.5)
        check("[gdemo] pointer down at" in log(), "pointer events reach the client process")
        check("[gdemo] text a" in log() and "[gdemo] text b" in log(), "keyboard events reach the client process")
        c("screendump " + os.path.join(OUT, "d1.ppm"), 1)
        ppm = open(os.path.join(OUT, "d1.ppm"), "rb").read()
        hdr_end = 0
        nl = 0
        while nl < 3:
            if ppm[hdr_end] == 10:
                nl += 1
            hdr_end += 1
        px = ppm[hdr_end:]
        green = sum(1 for i in range(0, len(px) - 2, 3) if px[i] == 0x20 and px[i + 1] == 0xb0 and px[i + 2] == 0x50)
        check(green > 5000, "the client's pixels are on the screen (%d window-green pixels)" % green)
    finally:
        q.kill()

if DESK:
    desktop()
if fails:
    print("FAILED:", fails)
    sys.exit(1)
print("all OS checks passed")
