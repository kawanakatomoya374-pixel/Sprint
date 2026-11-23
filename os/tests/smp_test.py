#!/usr/bin/env python3
"""Does the kernel itself run in parallel? Four processes make system calls as fast as they can; every system call runs the kernel's Sprint code. With one
kernel lock (the old design) more CPUs do not help (measured: 11.2 s on 1 CPU, 9.2 s on 2, 12.0 s on 4). With a Sprint VM per CPU the time falls with the CPU count."""
import os, re, subprocess, sys
OSB = sys.argv[1]
SP = os.environ.get("SPRINT", "build/sprint")
img = os.path.join(OSB, "sysbench.img")
subprocess.run([SP, "run", "--allow-read=" + OSB, "--allow-write=" + OSB, "os/boot/sprintboot.sp", os.path.join(OSB, "kernel32.elf"), img, "init=sysbench"], check=True, capture_output=True)
shots = os.path.join(OSB, "shots"); os.makedirs(shots, exist_ok=True)
t = {}
for cpus in (1, 2, 4):
    ser = os.path.join(shots, "sysbench%d.log" % cpus)
    if os.path.exists(ser): os.remove(ser)
    try:
        subprocess.run(["qemu-system-x86_64", "-m", "512", "-smp", str(cpus), "-drive", "format=raw,file=" + img, "-display", "none", "-no-reboot", "-serial", "file:" + ser,
                        "-device", "isa-debug-exit,iobase=0xf4,iosize=4"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=200)
    except subprocess.TimeoutExpired:
        pass
    m = re.search(r"sysbench: .* took (\d+) ms", open(ser, errors="replace").read())
    t[cpus] = int(m.group(1)) if m else None
print("4 x 60000 system calls: 1 cpu %s ms, 2 cpus %s ms, 4 cpus %s ms" % (t[1], t[2], t[4]))
ok = all(t.values()) and t[2] < t[1] * 0.7 and t[4] < t[1] * 0.45
print(("ok   " if ok else "FAIL ") + "kernel work scales with the number of CPUs (no kernel lock)")
sys.exit(0 if ok else 1)
