# lxrun: the generic way to run Linux programs on a disk: starts fsd, netd and linuxd, reads /run.list from the disk (one command per line: path TAB arg0 TAB arg1 ...,
# a field that starts with "ENV:" goes to the environment) and runs the lines one after the other. Used by os/tests/pack_run.py.
import psys as sys
import ipc
import io
import fsclient

let fsd = sys.spawn("fsd")
let netd = sys.spawn("netd")
let fs = fsclient.connect(5000)
for i in range(500):
    if ipc.lookup("net") != nil:
        break
    sys.sleep_ms(10)
let lxd = sys.spawn("linuxd")
let srv = nil
for i in range(2000):
    srv = ipc.lookup("linux")
    if srv != nil:
        break
    sys.sleep_ms(10)
print("lxrun: linuxd is pid", srv)
io.flush()
ipc.send(srv, "verbose")
ipc.recv_from()

func run(path, args, env):
    ipc.send(srv, "run\t" .. path .. "\t" .. args.join("\x1f") .. "\t" .. env.join("\x1f"))
    while true:
        let m = ipc.recv_from()
        let q = m[1].split("\t")
        if q[0] == "err":
            print("lxrun: " .. path .. ": " .. q[1])
            io.flush()
            return -1
        elif q[0] == "exit":
            print("lxrun: " .. path .. " exited with " .. q[2] .. " at " .. to_string(sys.ms()) .. " ms")
            io.flush()
            return to_int(q[2])

func join_args(path, args):
    let out = [path]
    for a in args:
        out.append(a)
    return out

let lines = fs.read_file("/run.list").split("\n")
for line in lines:
    if line.trim() == "":
        continue
    if line.starts_with("SNAP:"):
        ipc.send(srv, "snap\t" .. line.slice(5))
        let sr = ipc.recv_from()
        print("lxrun: snapshot of " .. line.slice(5) .. ": " .. sr[1])
        io.flush()
        continue
    if line.starts_with("VERBOSE:"):
        ipc.send(srv, "verbose\t" .. line.slice(8))
        ipc.recv_from()
        continue
    let f = line.split("\t")
    let args = []
    let env = ["HOME=/root", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C"]
    for i in range(1, len(f)):
        if f[i].starts_with("ENV:"):
            env.append(f[i].slice(4))
        else:
            args.append(f[i])
    print("lxrun: starting " .. f[0] .. " at " .. to_string(sys.ms()) .. " ms")
    io.flush()
    run(f[0], join_args(f[0], args), env)
print("lxrun: done")
io.flush()
ipc.send(srv, "quit")
sys.wait(lxd)
ipc.send(ipc.lookup("net"), "quit")
sys.wait(netd)
ipc.send(fsd, "quit")
sys.wait(fsd)
