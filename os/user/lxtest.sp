# lxtest: starts the file system server and the Linux personality server and runs the Linux programs found on the disk (the QEMU test os-linux-test runs this as the
# init program). Prints what each program printed (linuxd forwards their output to the serial port) and how it ended.
import psys as sys
import ipc
import io

let fsd = sys.spawn("fsd")
let lxd = sys.spawn("linuxd")
let srv = nil
for i in range(500):
    srv = ipc.lookup("linux")
    if srv != nil:
        break
    sys.sleep_ms(10)
print("lxtest: linuxd is pid", srv)
io.flush()

func run(path, args, env):
    ipc.send(srv, "run\t" .. path .. "\t" .. args.join("\x1f") .. "\t" .. env.join("\x1f"))
    let pid = nil
    while true:
        let m = ipc.recv_from()
        let q = m[1].split("\t")
        if q[0] == "ok":
            pid = to_int(q[1])
        elif q[0] == "err":
            print("lxtest: " .. path .. ": " .. q[1])
            io.flush()
            return -1
        elif q[0] == "exit":
            print("lxtest: " .. path .. " exited with " .. q[2])
            io.flush()
            return to_int(q[2])

ipc.send(srv, "verbose")
ipc.recv_from()
let progs = ["/bin/hello", "/bin/files", "/bin/proc", "/bin/hello_dyn", "/bin/glibc", "/bin/dl", "/bin/threads", "/bin/threads_glibc", "/bin/socks"]

for p in progs:
    run(p, [p, "one", "two words"], ["HOME=/root", "LANG=C"])
# real programs from the host's distribution (dash, coreutils, sed ...): a shell script with pipes and subshells
run("/usr/bin/dash", ["dash", "/lx/script.sh"], ["PATH=/usr/bin", "HOME=/root"])
print("lxtest: missing program:", run("/bin/nothere", ["x"], []))
print("lxtest: done")
io.flush()
ipc.send(srv, "quit")
sys.wait(lxd)
ipc.send(fsd, "quit")
sys.wait(fsd)
