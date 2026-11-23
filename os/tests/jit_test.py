#!/usr/bin/env python3
"""Is the JIT really on inside SprintOS? Boot the kernel twice (kernel command line `kbench` with and without `nojit`), run the JIT benchmark (stdlib/jbench.sp) in
the kernel's own Sprint VM, and check that the JIT makes loops, recursion, objects, arrays and floats several times faster than the interpreter alone."""
import os, re, subprocess, sys
OSB = sys.argv[1]
fails = []
def run(opts):
    img = os.path.join(OSB, "kbench.img")
    subprocess.run([os.environ.get("SPRINT", "build/sprint"), "run", "--allow-read=" + OSB, "--allow-write=" + OSB, "os/boot/sprintboot.sp", os.path.join(OSB, "kernel32.elf"), img, opts],
                   check=True, capture_output=True)
    ser = os.path.join(OSB, "shots", "kbench.log")
    os.makedirs(os.path.dirname(ser), exist_ok=True)
    if os.path.exists(ser): os.remove(ser)
    try:
        subprocess.run(["qemu-system-x86_64", "-m", "256", "-drive", "format=raw,file=" + img, "-display", "none", "-no-reboot", "-serial", "file:" + ser,
                        "-device", "isa-debug-exit,iobase=0xf4,iosize=4"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
    except subprocess.TimeoutExpired:
        pass
    return {m.group(1): int(m.group(2)) for m in re.finditer(r"kbench (.+?): (\d+) ms", open(ser, errors="replace").read())}
on = run("init=sleeper kbench")
off = run("init=sleeper kbench nojit")
need = {"ints 20M": 3, "fib(30)": 3, "objects 5M": 5, "arrays 2M": 3, "floats 10M": 3}
for name, ratio in need.items():
    ok = name in on and name in off and off[name] >= ratio * max(on[name], 1)
    print(("ok   " if ok else "FAIL ") + "the kernel's JIT speeds up %s: %s ms with, %s ms without (at least %dx)" % (name, on.get(name), off.get(name), ratio))
    if not ok: fails.append(name)
sys.exit(1 if fails else 0)
