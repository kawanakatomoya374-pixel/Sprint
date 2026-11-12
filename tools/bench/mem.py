#!/usr/bin/env python3
"""Memory / GC comparison: wall time and peak RSS of Sprint (JIT on) and LuaJIT for each tools/bench/mem/NAME.sp + NAME.lua.
usage: python3 tools/bench/mem.py [sprint] [names...]"""
import os, sys, subprocess, time, glob
sp = sys.argv[1] if len(sys.argv) > 1 and os.path.exists(sys.argv[1]) else "build/sprint"
names = [a for a in sys.argv[1:] if not os.path.exists(a)]
d = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mem")
if not names:
    names = sorted(os.path.basename(f)[:-3] for f in glob.glob(d + "/*.sp"))
def run(cmd):
    best = None
    for _ in range(3):
        t0 = time.time()
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        out = p.stdout.read(); _, st, ru = os.wait4(p.pid, 0)
        dt = time.time() - t0
        if best is None or dt < best[0]: best = (dt, ru.ru_maxrss / 1024.0, out.decode().split())
    return best
print("%-9s %7s %8s | %7s %8s | %6s %6s  %s" % ("bench", "sp s", "sp MB", "lj s", "lj MB", "t/lj", "MB/lj", "same"))
for n in names:
    a = run([sp, "run", "%s/%s.sp" % (d, n)])
    b = run(["luajit", "%s/%s.lua" % (d, n)])
    print("%-9s %7.2f %8.1f | %7.2f %8.1f | %6.2f %6.2f  %s" % (n, a[0], a[1], b[0], b[1], a[0] / b[0], a[1] / b[1], "ok" if a[2] == b[2] else "DIFF"))
