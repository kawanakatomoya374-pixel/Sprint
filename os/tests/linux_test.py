#!/usr/bin/env python3
"""Linux programs on SprintOS. Static-pie programs built with musl-gcc are put on a SprintFS disk; init=lxtest starts the file system server and linuxd (the Linux personality
server, Sprint). The kernel forwards each program's `syscall` instruction to linuxd as a message; linuxd answers it (ELF loading, memory, files, time, ...) with the lx
mechanisms (map / copy / start / reply). The host checks what the programs printed and what they left on the disk."""
import os, shutil, subprocess, sys, tempfile
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
glibc_ok = subprocess.run(["gcc", "-O2", "-pie", "-fPIE", "-o", os.path.join(tmp, "glibc"), os.path.join(src, "glibc.c"), "-lm"], capture_output=True).returncode == 0
glibc_ok = glibc_ok and subprocess.run(["gcc", "-O2", "-pie", "-fPIE", "-o", os.path.join(tmp, "dl"), os.path.join(src, "dl.c"), "-ldl"], capture_output=True).returncode == 0
glibc_ok = glibc_ok and subprocess.run(["gcc", "-O2", "-pie", "-fPIE", "-pthread", "-o", os.path.join(tmp, "threads_glibc"), os.path.join(src, "threads.c")], capture_output=True).returncode == 0
check(glibc_ok, "gcc builds glibc dynamic PIE programs")
for name, flags in (("hello", ["-static-pie"]), ("files", ["-static-pie"]), ("proc", ["-static-pie"]), ("threads", ["-static-pie", "-pthread"]), ("socks", ["-static-pie"]), ("hello_dyn", ["-pie", "-fPIE"])):
    r = subprocess.run(["musl-gcc"] + flags + ["-O2", "-o", os.path.join(tmp, name), os.path.join(src, name.replace("_dyn", "") + ".c")], capture_output=True, text=True)
    check(r.returncode == 0, "musl-gcc builds %s (%s)" % (name, " ".join(flags)))
fsimg = os.path.join(tmp, "fs.img")
def tool(*a):
    return subprocess.run([SP, "run", "--allow-read=" + tmp, "--allow-write=" + tmp, "tools/sprintfs.sp", fsimg] + list(a), capture_output=True, text=True)
tool("mkfs", "40"); tool("mkdir", "/bin"); tool("mkdir", "/lx")
open(os.path.join(tmp, "input.txt"), "w").write("hello from the SprintFS disk\nsecond line\n")
tool("mkdir", "/lib"); import shutil; shutil.copy("/lib/ld-musl-x86_64.so.1", os.path.join(tmp, "ld-musl")); tool("put", os.path.join(tmp, "ld-musl"), "/lib/ld-musl-x86_64.so.1")
if glibc_ok:
    tool("mkdir", "/lib64"); tool("mkdir", "/lib/x86_64-linux-gnu")
    for host, guest in (("/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2", "/lib64/ld-linux-x86-64.so.2"), ("/lib/x86_64-linux-gnu/libc.so.6", "/lib/x86_64-linux-gnu/libc.so.6")):
        shutil.copy(os.path.realpath(host), os.path.join(tmp, "glibc_lib")); tool("put", os.path.join(tmp, "glibc_lib"), guest)
    tool("put", os.path.join(tmp, "glibc"), "/bin/glibc"); tool("put", os.path.join(tmp, "dl"), "/bin/dl"); tool("put", os.path.join(tmp, "threads_glibc"), "/bin/threads_glibc")
REAL = ["dash", "cat", "sort", "sed", "ls", "echo", "wc", "tr", "head"]
made = set()
def put_real(binpath):
    """a program of the host's distribution with the shared libraries it needs, at the same paths"""
    real = os.path.realpath(binpath)
    deps = [real]
    for line in subprocess.run(["ldd", real], capture_output=True, text=True).stdout.splitlines():
        parts = line.split()
        if "=>" in line and len(parts) >= 3 and parts[2].startswith("/"): deps.append(parts[2])
        elif parts and parts[0].startswith("/"): deps.append(parts[0])
    for d in deps:
        guest = os.path.join("/usr/bin", os.path.basename(binpath)) if d == real else d
        if guest in made: continue
        made.add(guest)
        parent = ""
        for comp in os.path.dirname(guest).strip("/").split("/"):
            parent += "/" + comp
            if parent not in made: made.add(parent); tool("mkdir", parent)
        shutil.copy(os.path.realpath(d), os.path.join(tmp, "dep")); tool("put", os.path.join(tmp, "dep"), guest)
for b in REAL:
    w = shutil.which(b)
    if w: put_real(w)
open(os.path.join(tmp, "script.sh"), "w").write("""echo "shell works"
printf 'b\\na\\nc\\n' | sort
ls /lx | sort
cat /lx/input.txt | sed 's/hello/HELLO/' | head -1
for i in 1 2 3; do echo -n "$i "; done; echo
x=$(echo subshell); echo "got $x"
echo "done" | tr a-z A-Z
exit 5
""")
tool("put", os.path.join(tmp, "script.sh"), "/lx/script.sh")
tool("put", os.path.join(tmp, "socks"), "/bin/socks"); tool("mkdir", "/tmp"); tool("put", os.path.join(tmp, "threads"), "/bin/threads"); tool("put", os.path.join(tmp, "proc"), "/bin/proc"); tool("put", os.path.join(tmp, "hello_dyn"), "/bin/hello_dyn")
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
check("entry: out" in L and "entry: input.txt" in L and "entries=3" in L, "opendir / readdir (getdents64)")
check("missing: No such file or directory" in L, "errno from a missing file")
check("cwd=/bin" in L, "getcwd")
check("lxtest: /bin/files exited with 0" in L, "second program exits 0")
check("child reaped: captured" in L and "first=[hello from a Linux program on SprintOS" in L, "fork + pipe + dup2 + execve: the exec'd program's output is read through the pipe")
check("exec'd program status: exited=1 code=7" in L, "waitpid: the exit status of the exec'd program")
check("three children: sum of codes=60" in L, "fork + exit codes + wait4 (three children)")
check("fork copy: parent sees 1, child exited 2" in L, "fork copies the address space")
check("wait without children: ECHILD" in L, "wait with no children")
check("slept about right" in L, "nanosleep blocks the program, not the server")
check("blocking pipe reads: 3 ticks" in L, "a pipe read blocks until the writer writes")
check("hello from a Linux program on SprintOS" in L.split("dynamic")[0] or "uname: Linux" in L, "(static programs ran)")
check("lxtest: /bin/hello_dyn exited with 7" in L, "a dynamically linked (musl ld.so) program runs and exits")
check("glibc hello, argc=3" in L and "sqrt(2)=1.414214 strlen=3" in L and "lxtest: /bin/glibc exited with 3" in L, "a glibc dynamically linked program (ld-linux, libc.so.6) runs")
check("threads done: counter=2000 sum=12 main tls=0" in L and "short threads: 20 counter=12000" in L, "pthreads (clone with shared memory), mutex + condition variable (futex), thread-local storage, join")
check(L.count("threads done: counter=2000 sum=12 main tls=0") == 2 and L.count("short threads: 20 counter=12000") == 2, "the same threads program built against glibc (clone3 falls back to clone, robust lists, rseq refused)")
check("shell works" in L and "a\nb\nc" in L.replace("\r", "") and "HELLO from the SprintFS disk" in L, "dash from the distribution runs a script: pipes, sort, ls, sed, cat, head")
check("1 2 3" in L and "got subshell" in L and "DONE" in L, "dash: loops, command substitution (fork + pipe), tr")
check("lxtest: /usr/bin/dash exited with 5" in L, "the script's exit status")
check("dlopen: ok" in L and "dlsym: serialize=found compile=found" in L, "dlopen / dlsym of a real shared library (libpcre2) finds its symbols")
check("socketpair: ping" in L and "after shutdown: read=0" in L, "socketpair and shutdown(SHUT_WR) give EOF")
check("bind unix: 0" in L and "unix server got: hello unix" in L and "unix echo: reply!" in L, "AF_UNIX stream sockets: bind, listen, accept, connect between processes")
check("bind tcp: 0" in L and "listening on port 8080" in L and "epoll: 1 ready, listener=1" in L, "loopback TCP: bind/listen, getsockname, epoll on the listening socket")
check("tcp loopback: 3 bytes then EOF after 1 wakeups" in L, "loopback TCP: nonblocking accept4, epoll, data and EOF")
check("poll after close: 1 hup=1" in L and "connect refused: yes" in L, "poll reports hang-up; connecting to nothing gives ECONNREFUSED")
check("udp loopback: datagram" in L, "UDP datagrams on the loopback")
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
