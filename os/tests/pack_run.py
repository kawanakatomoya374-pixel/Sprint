#!/usr/bin/env python3
"""Runs Linux programs from C-OS app packs on SprintOS (QEMU). usage:
    pack_run.py --img IMG [--packs lua,w3m] [--disk-mb 512] [--mem 1024] [--timeout 1800] [--net] [--keep DISK] -- CMD [ARG...] [-- CMD ...]
The packs (folders of C-OS-APPS, or $COS_APPS) are installed with tools/packinstall.sp into a fresh SprintFS image, /run.list gets the commands, init=lxrun runs them.
The serial log goes to build/os/shots/packrun.log."""
import argparse, os, subprocess, sys, tempfile, time
ap = argparse.ArgumentParser()
ap.add_argument("--img", required=True); ap.add_argument("--trace", default=""); ap.add_argument("--packs", default=""); ap.add_argument("--disk-mb", type=int, default=256); ap.add_argument("--mem", type=int, default=512)
ap.add_argument("--timeout", type=int, default=1800); ap.add_argument("--keep", default=""); ap.add_argument("--reuse", default=""); ap.add_argument("--smp", type=int, default=2)
ap.add_argument("--http", default="", help="serve this HTML page on the host 127.0.0.1:18090 (10.0.2.2:18090 in the guest)")
ap.add_argument("--files", default="", help="host:guest,host:guest extra files")
ap.add_argument("cmds", nargs=argparse.REMAINDER)
a = ap.parse_args()
SP = os.environ.get("SPRINT", "build/sprint")
COSAPPS = os.environ.get("COS_APPS", "/home/user/C-OS-APPS")
OUT = os.path.join(os.path.dirname(a.img), "shots"); os.makedirs(OUT, exist_ok=True)
tmp = tempfile.mkdtemp()
disk = a.reuse or os.path.join(tmp, "disk.img")
def tool(*args, allow=()):
    return subprocess.run([SP, "run", "--max-heap", "8589934592", "--allow-read=" + tmp, "--allow-write=" + tmp, "--allow-read=" + os.path.dirname(os.path.abspath(disk)), "--allow-write=" + os.path.dirname(os.path.abspath(disk))] + ["--allow-read=" + x for x in allow] + ["tools/sprintfs.sp", disk] + list(args), capture_output=True, text=True)
if not a.reuse:
    r = tool("mkfs", str(a.disk_mb)); assert r.returncode == 0, r.stderr
    for name in [x for x in a.packs.split(",") if x]:
        pd = name if os.path.isabs(name) else os.path.join(COSAPPS, name if "/" in name else ("apps/" + name))
        t0 = time.time()
        r = subprocess.run([SP, "run", "--max-heap", "8589934592", "--allow-read=" + tmp, "--allow-read=" + COSAPPS, "--allow-write=" + tmp, "tools/packinstall.sp", disk, pd, "/"], capture_output=True, text=True)
        print("install %s: %s (%.0f s)" % (name, (r.stdout.strip().splitlines() or [r.stderr.strip()[:200]])[-1], time.time() - t0)); sys.stdout.flush()
        if r.returncode != 0: print(r.stderr[:500]); sys.exit(1)
def must(r):
    if r.returncode != 0 and "ENOENT" not in r.stderr:
        print("host tool failed:", r.stderr[:300]); sys.exit(1)
for spec in [x for x in a.files.split(",") if x]:
    h, g = spec.split(":"); import shutil; shutil.copy(h, os.path.join(tmp, "f")); tool("rm", g); must(tool("put", os.path.join(tmp, "f"), g))
cmds, cur = [], []
for x in a.cmds:
    if x == "--":
        if cur: cmds.append(cur); cur = []
    else: cur.append(x)
if cur: cmds.append(cur)
open(os.path.join(tmp, "run.list"), "w").write(("VERBOSE:" + a.trace + "\n" if a.trace else "") + "\n".join("\t".join(c) for c in cmds) + "\n")
tool("rm", "/run.list"); must(tool("put", os.path.join(tmp, "run.list"), "/run.list"))
if a.http:
    import socket, threading
    def serve():
        ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); ls.bind(("127.0.0.1", 18090)); ls.listen(8)
        def h(c):
            try:
                c.recv(4096); body = a.http.encode()
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
            finally: c.close()
        while True:
            c, _ = ls.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
    threading.Thread(target=serve, daemon=True).start()
ser = os.path.join(OUT, "packrun.log")
if os.path.exists(ser): os.remove(ser)
q = subprocess.Popen(["qemu-system-x86_64", "-m", str(a.mem), "-smp", str(a.smp), "-drive", "format=raw,file=" + a.img + ",if=ide,index=0", "-drive", "format=raw,file=" + disk + ",if=none,id=d1,cache=unsafe", "-device", "virtio-blk-pci,drive=d1",
                      "-netdev", "user,id=n0", "-device", "e1000,netdev=n0", "-display", "none", "-no-reboot", "-serial", "file:" + ser, "-monitor", "unix:" + os.path.join(OUT, "mon.sock") + ",server,nowait"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
t0 = time.time(); seen = 0
while time.time() - t0 < a.timeout and q.poll() is None:
    time.sleep(2)
    L = open(ser, errors="replace").read()
    if len(L) > seen: sys.stdout.write(L[seen:]); sys.stdout.flush(); seen = len(L)
    if "lxrun: done" in L: break
q.kill()
if a.keep: import shutil; shutil.copy(disk, a.keep)
print("--- finished after %.0f s" % (time.time() - t0))
