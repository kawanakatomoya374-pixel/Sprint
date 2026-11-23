#!/usr/bin/env python3
"""Boot-menu checks for the Sprint OS loaders: the BIOS loader, the UEFI loader and the hybrid image under both firmwares.
usage: python3 os/tests/menu_test.py   (from the repository root, after `make build/os/kernel.elf`; needs qemu, and OVMF for the UEFI cases)

For every loader: the default entry boots after the countdown, a number key selects and boots an entry, `quiet` silences the serial port
(the kernel's log is gone, the self-test still runs), and `e` edits the command line (init=init -> init=boot)."""
import os, shutil, socket, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPRINT = os.path.join(ROOT, "build/sprint")
OSB = os.path.join(ROOT, "build/os")
OVMF = "/usr/share/ovmf/OVMF.fd"
fails = []

def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what, flush=True)
    if not cond:
        fails.append(what)

if shutil.which("qemu-system-x86_64") is None:
    print("menu-test: qemu-system-x86_64 not found, skipped"); sys.exit(0)
for f in (os.path.join(OSB, "kernel.elf"), os.path.join(OSB, "kernel32.elf")):
    if not os.path.exists(f):
        print("menu-test: %s missing, skipped" % f); sys.exit(0)
have_uefi = os.path.exists(OVMF)

wd = tempfile.mkdtemp(prefix="sprint-menu-")
SPEC = "25;Sprint OS desktop|init=boot;Self-test|init=init;Quiet self-test|init=init quiet"
SHORT = "3;Sprint OS desktop|init=boot;Self-test|init=init"

def build(script, out, spec, extra=()):
    subprocess.run([SPRINT, "run", f"--allow-read={OSB}", f"--allow-write={wd}", os.path.join(ROOT, "os/boot", script), os.path.join(OSB, "kernel32.elf"),
                    f"{wd}/{out}", spec, *extra], check=True, capture_output=True)

def run(img, uefi, keys=(), until=None, timeout=90, tail=2.0):
    ser = f"{wd}/serial.log"; mon = f"{wd}/mon.sock"
    for f in (ser, mon):
        if os.path.exists(f):
            os.remove(f)
    fw = ["-bios", OVMF] if uefi else []
    q = subprocess.Popen(["qemu-system-x86_64", "-m", "256", *fw, "-drive", f"format=raw,file={wd}/{img}", "-display", "none", "-no-reboot", "-serial", "file:" + ser,
                          "-monitor", f"unix:{mon},server,nowait"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            if os.path.exists(mon):
                break
            time.sleep(0.1)
        time.sleep(0.5)
        s = socket.socket(socket.AF_UNIX); s.connect(mon); s.settimeout(5); time.sleep(0.3); s.recv(4096)
        t0 = time.time(); pending = sorted(keys)
        def log():
            return open(ser, errors="replace").read() if os.path.exists(ser) else ""
        while time.time() - t0 < timeout:
            while pending and time.time() - t0 >= pending[0][0]:
                s.send(("sendkey " + pending.pop(0)[1] + "\n").encode()); time.sleep(0.3)
            if until and until in log():
                break
            time.sleep(0.3)
        time.sleep(tail)
        return log()
    finally:
        q.kill(); q.wait()

# (name, image, uefi?) ; the first key is sent once the menu is up
cases = [("BIOS loader", "bios.img", False, 5), ("hybrid image under BIOS", "hybrid.img", False, 5)]
build("sprintboot.sp", "bios.img", SPEC)
build("sprintboot.sp", "bios-short.img", SHORT)
build("hybridboot.sp", "hybrid.img", SPEC, (os.path.join(OSB, "kernel.elf"),))
if have_uefi:
    build("uefiboot.sp", "uefi.img", SPEC, (os.path.join(OSB, "kernel.elf"),))
    cases += [("UEFI loader", "uefi.img", True, 14), ("hybrid image under UEFI", "hybrid.img", True, 14)]

for name, img, uefi, t in cases:
    log = run(img, uefi, keys=[(t, "2")], until="init: done", timeout=120)
    check("Sprint OS boot menu" in log and "first process: init" in log and "init: done" in log, f"{name}: key 2 selects and boots the self-test")
    log = run(img, uefi, keys=[(t, "3")], timeout=45, tail=8)
    check("Sprint OS boot menu" in log and "[kernel]" not in log and "init:" not in log, f"{name}: the quiet entry silences the serial port")
    log = run(img, uefi, keys=[(t, "down"), (t + 1, "e"), (t + 2, "backspace"), (t + 3, "backspace"), (t + 4, "backspace"), (t + 5, "backspace"),
                               (t + 6, "b"), (t + 7, "o"), (t + 8, "o"), (t + 9, "t"), (t + 10, "ret")], until="[desktop] ready", timeout=120)
    check("command line (Enter: boot" in log and "first process: boot" in log, f"{name}: e edits the command line (init=init -> init=boot)")

log = run("bios-short.img", False, until="[desktop] ready", timeout=60)
check("Booting the selected entry in 3 s" in log and "first process: boot" in log and "[desktop] ready" in log, "BIOS loader: the default entry boots when the countdown ends")
if have_uefi:
    build("uefiboot.sp", "uefi-short.img", SHORT, (os.path.join(OSB, "kernel.elf"),))
    log = run("uefi-short.img", True, until="[desktop] ready", timeout=90)
    check("Booting the selected entry in 3 s" in log and "first process: boot" in log and "[desktop] ready" in log, "UEFI loader: the default entry boots when the countdown ends")

shutil.rmtree(wd, ignore_errors=True)
if fails:
    print("FAILED:", fails); sys.exit(1)
print("all boot-menu checks passed")
