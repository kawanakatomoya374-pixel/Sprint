#!/usr/bin/env python3
"""The file manager. Part 1: init=exptest runs stdlib/explorer.sp on the real file system server (a SprintFS disk made on the host) with synthetic events: a binary file
(70000 bytes) is copied, a text file moved and renamed, a folder deleted after the confirmation; the host then checks the disk with fsck and reads the files back.
Part 2: the desktop image with the same kind of disk: a double click on the Explorer icon starts the explorer process, which opens a window through guid and lists the disk."""
import os, socket, subprocess, sys, tempfile, time
IMG, DESK = sys.argv[1], sys.argv[2]
SP = os.environ.get("SPRINT", "build/sprint")
OUT = os.path.join(os.path.dirname(IMG), "shots")
os.makedirs(OUT, exist_ok=True)
fails = []
def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c: fails.append(what)
tmp = tempfile.mkdtemp()
def tool(img, *a):
    return subprocess.run([SP, "run", "--allow-read=" + tmp, "--allow-write=" + tmp, "tools/sprintfs.sp", img] + list(a), capture_output=True, text=True)
fsimg = os.path.join(tmp, "fs.img")
tool(fsimg, "mkfs", "8")
ser = os.path.join(OUT, "explorer1.log")
if os.path.exists(ser): os.remove(ser)
try:
    subprocess.run(["qemu-system-x86_64", "-m", "256", "-smp", "2", "-drive", "format=raw,file=" + IMG + ",if=ide,index=0", "-drive", "format=raw,file=" + fsimg + ",if=ide,index=1",
                    "-display", "none", "-no-reboot", "-serial", "file:" + ser, "-device", "isa-debug-exit,iobase=0xf4,iosize=4"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=240)
except subprocess.TimeoutExpired:
    pass
L = open(ser, errors="replace").read()
check("exptest: binary written, 70000 bytes" in L and "exptest: binary read back equal: true" in L, "a 70000-byte binary file goes through the file system server and back unchanged")
check("exptest: root: docs" in L, "the folder list shows the disk")
check("exptest: backup: data.bin,moved.txt" in L, "copy of a binary file, move and rename in place")
check("exptest: copy equal: true" in L, "the pasted copy equals the original byte for byte")
check("exptest: root after delete: Backup" in L, "a folder is deleted after the confirmation (recursively)")
check("exptest: done" in L, "the test program finished")
# the host looks at the disk
bin_ = bytes(((i * 31 + (i >> 8)) & 255) for i in range(70000))
open(os.path.join(tmp, "orig.bin"), "wb").write(bin_)
r = tool(fsimg, "get", "/Backup/data.bin", os.path.join(tmp, "got.bin"))
got = open(os.path.join(tmp, "got.bin"), "rb").read() if os.path.exists(os.path.join(tmp, "got.bin")) else b""
check(got == bin_, "the host reads the copied binary file from the disk: identical")
r = tool(fsimg, "get", "/Backup/moved.txt", os.path.join(tmp, "m.txt"))
check(os.path.exists(os.path.join(tmp, "m.txt")) and open(os.path.join(tmp, "m.txt")).read() == "a text file\n", "the moved and renamed text file is on the disk")
r = tool(fsimg, "fsck")
check(r.returncode == 0 and "error" not in (r.stdout + r.stderr).lower().replace("0 errors", ""), "fsck on the host: the volume is clean (%s)" % (r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()[:80]))

# part 2: the desktop
ser2, mon = os.path.join(OUT, "explorer2.log"), os.path.join(OUT, "explorer.sock")
for f in (ser2, mon):
    if os.path.exists(f): os.remove(f)
img2 = os.path.join(tmp, "fs2.img")
tool(img2, "mkfs", "8")
open(os.path.join(tmp, "h.txt"), "w").write("hello\n")
tool(img2, "mkdir", "/Pictures"); tool(img2, "put", os.path.join(tmp, "h.txt"), "/hello.txt")
q = subprocess.Popen(["qemu-system-x86_64", "-m", "512", "-smp", "2", "-drive", "format=raw,file=" + DESK, "-drive", "format=raw,file=" + img2 + ",if=ide,index=1",
                      "-display", "none", "-no-reboot", "-serial", "file:" + ser2, "-monitor", "unix:" + mon + ",server,nowait"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        if os.path.exists(mon): break
        time.sleep(0.1)
    s = socket.socket(socket.AF_UNIX); s.connect(mon); time.sleep(0.5)
    def c(x, t=0.15):
        s.send((x + "\n").encode()); time.sleep(t)
    def log():
        return open(ser2, errors="replace").read()
    for _ in range(400):
        if "[guid] ready" in log(): break
        time.sleep(0.2)
    for _ in range(12): c("mouse_move -60 -45", 0.05)
    c("mouse_move 30 495", 0.3)
    for _ in range(2):
        c("mouse_button 1", 0.08); c("mouse_button 0", 0.08)
    for _ in range(100):
        if "[explorer] window open" in log(): break
        time.sleep(0.2)
    check("[guid] open Explorer" in log(), "a double click on the Explorer icon starts it")
    check("[explorer] window open, 2 entries in /" in log(), "the explorer process opened a window through guid and listed the disk (2 entries)")
    c("screendump " + os.path.join(OUT, "explorer.ppm"), 1.5)
    data = open(os.path.join(OUT, "explorer.ppm"), "rb").read()
    check(len(data) > 1000 and data.count(b"\xcc\xe8\xff") + data.count(b"\xf7\xd2\x5a") > 20, "the window is on the screen (folder icons drawn)")
finally:
    q.kill()
sys.exit(1 if fails else 0)
