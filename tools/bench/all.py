#!/usr/bin/env python3
"""All benchmarks against LuaJIT: wall time (best of N), output equality, ratio, geometric mean, worst first.
usage: python3 tools/bench/all.py [-n RUNS] [-s SPRINT] [-t SECONDS] [names...]   (run from the repository root; env passes through)"""
import os, sys, subprocess, time, glob, math, argparse
ap = argparse.ArgumentParser()
ap.add_argument("-n", type=int, default=3)
ap.add_argument("-s", default="build/sprint")
ap.add_argument("-t", type=float, default=60.0)
ap.add_argument("--json")
ap.add_argument("names", nargs="*")
a = ap.parse_args()
d = os.path.dirname(os.path.abspath(__file__))
names = a.names or sorted(os.path.basename(f)[:-3] for f in glob.glob(d + "/*.sp") if os.path.exists(d + "/lua/" + os.path.basename(f)[:-3] + ".lua"))
def run(cmd):
    best, out = None, ""
    for _ in range(a.n):
        t0 = time.time()
        try:
            p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=a.t)
        except subprocess.TimeoutExpired:
            return None, "TIMEOUT"
        dt = time.time() - t0
        if best is None or dt < best: best = dt
        out = p.stdout.decode(errors="replace")
    return best, " ".join(out.split())
rows = []
for n in names:
    lj = d + "/lua/" + n + ".luajit.lua"
    if not os.path.exists(lj): lj = d + "/lua/" + n + ".lua"
    ts, os_ = run([a.s, "run", d + "/" + n + ".sp"])
    tl, ol = run(["luajit", lj])
    if ts is None or tl is None:
        rows.append((n, ts or 0, tl or 0, 0, "TIMEOUT")); continue
    ok = "ok" if os_ == ol else "DIFF"
    rows.append((n, ts, tl, ts / tl if tl > 0 else 0, ok))
rows.sort(key=lambda r: -r[3])
print("%-14s %8s %8s %7s  %s" % ("bench", "sprint", "luajit", "ratio", ""))
for r in rows: print("%-14s %8.3f %8.3f %7.2f  %s" % r)
good = [r for r in rows if r[4] == "ok" and r[3] > 0]
if good:
    g = math.exp(sum(math.log(max(r[3], 1e-3)) for r in good) / len(good))
    print("benchmarks %d  geomean ratio %.3f  (<=1.1: %d  <=1.5: %d  >1.5: %d)  wrong output: %d" % (
        len(good), g, sum(r[3] <= 1.1 for r in good), sum(r[3] <= 1.5 for r in good), sum(r[3] > 1.5 for r in good), sum(r[4] != "ok" for r in rows)))
if a.json:
    import json
    json.dump({r[0]: {"sprint": r[1], "luajit": r[2], "ratio": r[3], "ok": r[4]} for r in rows}, open(a.json, "w"), indent=1)
