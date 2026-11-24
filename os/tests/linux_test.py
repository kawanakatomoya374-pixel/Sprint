#!/usr/bin/env python3
"""Linux programs on SprintOS. Static-pie programs built with musl-gcc are put on a SprintFS disk; init=lxtest starts the file system server and linuxd (the Linux personality
server, Sprint). The kernel forwards each program's `syscall` instruction to linuxd as a message; linuxd answers it (ELF loading, memory, files, time, ...) with the lx
mechanisms (map / copy / start / reply). The host checks what the programs printed and what they left on the disk."""
import os, shutil, socket, subprocess, sys, tempfile, threading, time
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
glibc_ok = glibc_ok and subprocess.run(["gcc", "-O2", "-pie", "-fPIE", "-o", os.path.join(tmp, "signals_glibc"), os.path.join(src, "signals.c")], capture_output=True).returncode == 0
glibc_ok = glibc_ok and subprocess.run(["gcc", "-O2", "-pie", "-fPIE", "-pthread", "-o", os.path.join(tmp, "threads_glibc"), os.path.join(src, "threads.c")], capture_output=True).returncode == 0
check(glibc_ok, "gcc builds glibc dynamic PIE programs")
for name, flags in (("hello", ["-static-pie"]), ("files", ["-static-pie"]), ("proc", ["-static-pie"]), ("threads", ["-static-pie", "-pthread"]), ("socks", ["-static-pie"]), ("signals", ["-static-pie"]), ("procfs", ["-static-pie", "-pthread"]), ("nettest", ["-static-pie"]), ("hello_dyn", ["-pie", "-fPIE"])):
    r = subprocess.run(["musl-gcc"] + flags + ["-O2", "-o", os.path.join(tmp, name), os.path.join(src, name.replace("_dyn", "") + ".c")], capture_output=True, text=True)
    check(r.returncode == 0, "musl-gcc builds %s (%s)" % (name, " ".join(flags)))
fsimg = os.path.join(tmp, "fs.img")
def tool(*a):
    return subprocess.run([SP, "run", "--allow-read=" + tmp, "--allow-write=" + tmp, "tools/sprintfs.sp", fsimg] + list(a), capture_output=True, text=True)
tool("mkfs", "96"); tool("mkdir", "/bin"); tool("mkdir", "/lx")
open(os.path.join(tmp, "input.txt"), "w").write("hello from the SprintFS disk\nsecond line\n")
tool("mkdir", "/lib"); import shutil; shutil.copy("/lib/ld-musl-x86_64.so.1", os.path.join(tmp, "ld-musl")); tool("put", os.path.join(tmp, "ld-musl"), "/lib/ld-musl-x86_64.so.1")
if glibc_ok:
    tool("mkdir", "/lib64"); tool("mkdir", "/lib/x86_64-linux-gnu")
    for host, guest in (("/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2", "/lib64/ld-linux-x86-64.so.2"), ("/lib/x86_64-linux-gnu/libc.so.6", "/lib/x86_64-linux-gnu/libc.so.6")):
        shutil.copy(os.path.realpath(host), os.path.join(tmp, "glibc_lib")); tool("put", os.path.join(tmp, "glibc_lib"), guest)
    tool("put", os.path.join(tmp, "glibc"), "/bin/glibc"); tool("put", os.path.join(tmp, "signals_glibc"), "/bin/signals_glibc"); tool("put", os.path.join(tmp, "dl"), "/bin/dl"); tool("put", os.path.join(tmp, "threads_glibc"), "/bin/threads_glibc")
REAL = ["dash", "cat", "sort", "sed", "ls", "echo", "wc", "tr", "head", "curl"]
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
curl -s http://10.0.2.2:18090/hello; echo " curl rc=$?"\nexit 5\n""")
tool("put", os.path.join(tmp, "script.sh"), "/lx/script.sh")
# an app pack of C-OS (signed; see C-OS-APPS), installed by tools/packinstall.sp when a clone of that repository is at hand
COSAPPS = os.environ.get("COS_APPS", "/home/user/C-OS-APPS")
packs = []
for name in ("lua",):
    pd = os.path.join(COSAPPS, "apps", name)
    if os.path.exists(os.path.join(pd, "linuxpack.manifest")):
        r = subprocess.run([SP, "run", "--allow-read=" + tmp, "--allow-read=" + COSAPPS, "--allow-write=" + tmp, "tools/packinstall.sp", fsimg, pd, "/"], capture_output=True, text=True)
        check(r.returncode == 0 and "installed" in r.stdout, "packinstall: the %s pack passes its signature and SHA-256 checks and goes onto the disk" % name)
        if r.returncode == 0: packs.append(name)
tool("put", os.path.join(tmp, "procfs"), "/bin/procfs"); tool("put", os.path.join(tmp, "nettest"), "/bin/nettest"); tool("mkdir", "/etc"); open(os.path.join(tmp, "resolv.conf"), "w").write("nameserver 10.0.2.2\n"); tool("put", os.path.join(tmp, "resolv.conf"), "/etc/resolv.conf"); tool("put", os.path.join(tmp, "signals"), "/bin/signals"); tool("put", os.path.join(tmp, "socks"), "/bin/socks"); tool("mkdir", "/tmp"); tool("put", os.path.join(tmp, "threads"), "/bin/threads"); tool("put", os.path.join(tmp, "proc"), "/bin/proc"); tool("put", os.path.join(tmp, "hello_dyn"), "/bin/hello_dyn")
tool("put", os.path.join(tmp, "hello"), "/bin/hello"); tool("put", os.path.join(tmp, "files"), "/bin/files"); tool("put", os.path.join(tmp, "input.txt"), "/lx/input.txt")
ser = os.path.join(OUT, "linux.log")
if os.path.exists(ser): os.remove(ser)
# the host side of the network tests: an HTTP server (18090), a UDP echo (18091), a DNS server on port 53 (QEMU's 10.0.2.2 is the host)
BIGDATA = bytes((i * 13 + (i >> 8)) & 255 for i in range(300000))
def serve_http():
    ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); ls.bind(("127.0.0.1", 18090)); ls.listen(8)
    def h(c):
        try:
            req = c.recv(4096)
            body = BIGDATA if b"/big" in req else b"hello from the host"
            c.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        finally: c.close()
    while True:
        try: c, _ = ls.accept()
        except OSError: return
        threading.Thread(target=h, args=(c,), daemon=True).start()
def serve_udp():
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(("127.0.0.1", 18091))
    while True:
        d, a = u.recvfrom(2048); u.sendto(d.upper(), a)
def serve_dns():
    try:
        d = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); d.bind(("127.0.0.1", 53))
    except OSError: return
    while True:
        q, a = d.recvfrom(512)
        o = 12
        while q[o]: o += q[o] + 1
        o += 5
        r = bytearray(q[:o]); r[2] = 0x81; r[3] = 0x80; r[7] = 1
        r += bytes([0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 7])
        d.sendto(bytes(r), a)
for fn in (serve_http, serve_udp, serve_dns): threading.Thread(target=fn, daemon=True).start()
q = subprocess.Popen(["qemu-system-x86_64", "-m", "256", "-smp", "2", "-drive", "format=raw,file=" + IMG + ",if=ide,index=0", "-drive", "format=raw,file=" + fsimg + ",if=ide,index=1",
                      "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:17001-:7001", "-device", "e1000,netdev=n0",
                      "-display", "none", "-no-reboot", "-serial", "file:" + ser], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
fwd_reply = b""
connected = False
deadline = time.time() + 900
while time.time() < deadline and q.poll() is None:
    cur = open(ser, errors="replace").read() if os.path.exists(ser) else ""
    if "nettest: listening 7001" in cur and not connected:
        connected = True
        try:
            c = socket.create_connection(("127.0.0.1", 17001), timeout=15)
            c.sendall(b"hello through the forward"); c.shutdown(socket.SHUT_WR); c.settimeout(20)
            while True:
                d = c.recv(4096)
                if not d: break
                fwd_reply += d
            c.close()
        except OSError as e:
            print("host side of the server test:", e)
    if "lxtest: done" in cur: break
    time.sleep(0.5)
try: q.wait(timeout=5)
except subprocess.TimeoutExpired: q.kill()
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
check("hello from the host" in L.split("lxtest: /usr/bin/dash")[0] and " curl rc=0" in L, "curl from the distribution (libcurl and ~30 libraries) fetches a page over HTTP from the host through SprintOS's own TCP/IP stack")
check("lxtest: /usr/bin/dash exited with 5" in L, "the script's exit status")
check("dlopen: ok" in L and "dlsym: serialize=found compile=found" in L, "dlopen / dlsym of a real shared library (libpcre2) finds its symbols")
check("socketpair: ping" in L and "after shutdown: read=0" in L, "socketpair and shutdown(SHUT_WR) give EOF")
check("bind unix: 0" in L and "unix server got: hello unix" in L and "unix echo: reply!" in L, "AF_UNIX stream sockets: bind, listen, accept, connect between processes")
check("bind tcp: 0" in L and "listening on port 8080" in L and "epoll: 1 ready, listener=1" in L, "loopback TCP: bind/listen, getsockname, epoll on the listening socket")
check("tcp loopback: 3 bytes then EOF after 1 wakeups" in L, "loopback TCP: nonblocking accept4, epoll, data and EOF")
check("poll after close: 1 hup=1" in L and "connect refused: yes" in L, "poll reports hang-up; connecting to nothing gives ECONNREFUSED")
check("udp loopback: datagram" in L, "UDP datagrams on the loopback")
for tag, n in (("musl", 1), ("glibc", 2)):
    check(L.count("raise: usr1=1") >= n and L.count("kill + siginfo: usr2=1 signo=12 pid_ok=1") >= n, "signals (%s): sigaction handlers run on raise / kill, SA_SIGINFO gives siginfo" % tag)
    check(L.count("blocked: usr1=1 pending=1") >= n and L.count("unblocked: usr1=2") >= n, "signals (%s): a blocked signal waits and is delivered when unblocked" % tag)
    check(L.count("pause: r=-1 errno=EINTR alrm=1") >= n and L.count("busy loop interrupted by the timer: ticks>=3 is 1") >= n, "signals (%s): alarm interrupts pause(); a periodic timer interrupts a loop with no system calls" % tag)
    check(L.count("nanosleep: r=-1 errno=EINTR remaining>0=1") >= n and L.count("restart: read=1 c=z handler ran=1") >= n, "signals (%s): nanosleep gives EINTR; SA_RESTART restarts a blocked read" % tag)
    check(L.count("child killed: signaled=1 sig=15 chld=1") >= n, "signals (%s): SIGTERM ends a child by default, SIGCHLD handler runs" % tag)
    check(L.count("SIGSEGV handler: addr=") >= n and L.count("recovered from SIGSEGV") >= n and L.count("recovered from SIGFPE") >= n, "signals (%s): a page fault and a division by zero reach their handlers (siglongjmp out)" % tag)
    check(L.count("unhandled fault: signaled=1 sig=11") >= n and L.count("abort: sig=6") >= n, "signals (%s): an unhandled fault ends with SIGSEGV; abort() gives SIGABRT" % tag)
check("cmdline: 31 bytes" in L or "cmdline:" in L and "first=/bin/procfs" in L, "/proc/self/cmdline")
check("status: Name=procfs" in L and "cpuinfo: ok" in L and "meminfo: ok" in L and "uptime: ok" in L, "/proc/self/status, cpuinfo, meminfo, uptime")
check("maps:" in L and "stack=1 exe=1" in L, "/proc/self/maps lists the program and the [stack]")
check("exe: /bin/procfs" in L and "fd link: /lx/input.txt" in L and "stat /proc/self: dir=1" in L and "stat /proc/nothing: -1" in L, "readlink of /proc/self/exe and /proc/self/fd/N, stat of /proc paths")
check("fd entries: 4" in L or "fd entries: 5" in L, "/proc/self/fd can be listed")
check("pthread_getattr_np: 0 size>0=1" in L, "glibc/musl pthread_getattr_np works (it reads /proc/self/maps)")
check("nettest: connect=0" in L and "nettest: http: [HTTP/1.0 200 OK]" in L, "TCP client to a server on the host: connect, write, read until EOF")
check("nettest: big=300043" in L, "a 300000-byte download over TCP through netd, E1000 and QEMU's network")
check("nettest: nb connect=-1 einprogress=1" in L and "so_error=0" in L and "nb poll=1 out=1" in L, "nonblocking connect: EINPROGRESS, poll for writability, SO_ERROR")
check("nettest: closed port: ECONNREFUSED" in L, "connecting to a closed port gives ECONNREFUSED")
check("nettest: udp: UDP FROM SPRINTOS from 10.0.2.2:18091" in L, "UDP datagram to the host and the answer back (recvfrom with the source address)")
check("nettest: getaddrinfo: 192.0.2.7" in L, "getaddrinfo (the C library's resolver) asks the DNS server named in /etc/resolv.conf")
check("nettest: bind=0" in L and "nettest: accepted=1" in L and fwd_reply == b"HELLO THROUGH THE FORWARD", "a TCP server: the host connects through QEMU's port forward and gets the data back")
if "lua" in packs:
    check("lua\t42\tLua 5.5" in L, "the C-OS Lua pack: /usr/bin/lua runs (ELF interpreter /lib64/ld-linux-x86-64.so.2 is a link to a link, glibc 2.31 from the pack)")
    check("luajit\t50000005000000" in L, "the C-OS Lua pack: LuaJIT runs its JIT-compiled loop")
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
