# the first user process: preemption demo, then a parallel-speed-up measurement
import psys as sys
print("init: pid", sys.pid())
let a = sys.spawn("worker")
let b = sys.spawn("worker")
let c = sys.spawn("sleeper")
print("init: started", a, b, c)
print("init: worker", a, "exited with", sys.wait(a))
print("init: worker", b, "exited with", sys.wait(b))
print("init: sleeper", c, "exited with", sys.wait(c))
let t0 = sys.ms()
let ids = []
for i in range(4):
    ids.append(sys.spawn("burner"))
for id in ids:
    sys.wait(id)
print("init: 4 burners took", sys.ms() - t0, "ms")
# ---- IPC: shared memory and messages ----
import ipc
let kid = sys.spawn("ipckid")
let seg = ipc.shm_create(8192)
ipc.shm_write(seg[1], 0, "hello from init")
ipc.send(kid, to_string(seg[0]) .. " " .. to_string(sys.pid()))
print("init: ipc", ipc.recv())
print("init: ipc shared write seen:", ipc.shm_read(seg[1], 100, 5), ipc.shm_get(seg[1], 200))
let t1 = sys.ms()
let ok = true
for i in range(200):
    ipc.send(kid, to_string(i))
    if ipc.recv() != "pong " .. to_string(i):
        ok = false
print("init: ipc 200 round trips", "ok" if ok else "BAD", "in", sys.ms() - t1, "ms")
ipc.send(kid, "stop")
sys.wait(kid)
ipc.shm_close(seg[1])
print("init: done")
