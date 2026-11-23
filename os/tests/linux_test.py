#!/usr/bin/env python3
"""Linux programs on SprintOS. Static-pie programs built with musl-gcc are put on a SprintFS disk; init=lxtest starts the file system server and linuxd (the Linux personality
server, Sprint). The kernel forwards each program's `syscall` instruction to linuxd as a message; linuxd answers it (ELF loading, memory, files, time, ...) with the lx
mechanisms (map / copy / start / reply). The host checks what the programs printed and what they left on the disk."""
import os, subprocess, sys, tempfile
IMG = sys.argv[1]
SP = os.environ.get("SPRINT", "build/sprint")
OUT = os.path.join(os.path.dirname(IMG), "shots")
os.makedirs(OUT, exist_ok=True)
fails = []
def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c: fails.append(what)
tmp = tempfile.mkdtemp()
src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tests", "linux")
for name in ("hello", "files"):
    r = subprocess.run(["musl-gcc", "-static-pie", "-O2", "-o", os.path.join(tmp, name), os.path.join(src, name + ".c")], capture_output=True, text=True)
    check(r.returncode == 0, "musl-gcc builds %s as a static-pie program" % name)
fsimg = os.path.join(tmp, "fs.img")
def tool(*a):
    return subprocess.run([SP, "run", "--allow-read=" + tmp, "--allow-write=" + tmp, "tools/sprintfs.sp", fsimg] + list(a), capture_output=True, text=True)
tool("mkfs", "16"); tool("mkdir", "/bin"); tool("mkdir", "/lx")
open(os.path.join(tmp, "input.txt"), "w").write("hello from the SprintFS disk\nsecond line\n")
tool("put", os.path.join(tmp, "hello"), "/bin/hello"); tool("put", os.path.join(tmp, "files"), "/bin/files"); tool("put", os.path.join(tmp, "input.txt"), "/lx/input.txt")
ser = os.path.join(OUT, "linux.log")
if os.path.exists(ser): os.remove(ser)
try:
    subprocess.run(["qemu-system-x86_64", "-m", "256", "-smp", "2", "-drive", "format=raw,file=" + IMG + ",if=ide,index=0", "-drive", "format=raw,file=" + fsimg + ",if=ide,index=1",
                    "-display", "none", "-no-reboot", "-serial", "file:" + ser, "-device", "isa-debug-exit,iobase=0xf4,iosize=4"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=240)
except subprocess.TimeoutExpired:
    pass
L = open(ser, errors="replace").read()
check("lxtest: linuxd is pid" in L, "the Linux personality server starts")
check("hello from a Linux program on SprintOS" in L, "a static-pie musl program runs and prints through write()")
check("argc=3 [/bin/hello] [one] [two words]" in L, "argv reaches the program (initial stack)")
check("envp=2 first=HOME=/root" in L, "the environment reaches the program")
check("uname: Linux 6.1.0-sprintos x86_64" in L, "uname")
check("big malloc sum=5376" in L, "a 3 MiB malloc (mmap) is usable")
check("small mallocs ok=1 pid>0=1" in L, "200 small mallocs (brk) and getpid")
check("to stderr" in L, "stderr")
check("lxtest: /bin/hello exited with 7" in L, "the exit status comes back")
check("open input: ok" in L and "read 41 bytes: hello from the SprintFS disk" in L, "open + read of a file on the SprintFS disk through fsd")
check("size=41 regular=1" in L and "seek+read: [from ]" in L, "fstat, lseek")
check("fopen/fgets lines=2" in L, "stdio files: fopen, fprintf, fgets")
check("entry: out" in L and "entry: input.txt" in L and "entries=2" in L, "opendir / readdir (getdents64)")
check("missing: No such file or directory" in L, "errno from a missing file")
check("cwd=/bin" in L, "getcwd")
check("lxtest: /bin/files exited with 0" in L, "second program exits 0")
check("lxtest: /bin/nothere: cannot read" in L, "a missing program is reported")
check("lxtest: done" in L, "the test finished")
# the host looks at the disk
def get(path):
    out = os.path.join(tmp, "got")
    if os.path.exists(out): os.remove(out)
    tool("get", path, out)
    return open(out, "rb").read() if os.path.exists(out) else None
check(get("/lx/out/renamed.txt") == b"line 1\nline 2\n", "the file the program wrote and renamed is on the disk")
r = tool("fsck")
check(r.returncode == 0 and "clean" in r.stdout, "fsck on the host: the volume is clean")
sys.exit(1 if fails else 0)
