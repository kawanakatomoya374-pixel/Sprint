# ipckid: the child side of the IPC self-test. Opens the shared segment init created, answers pings.
import ipc
import psys as sys

let hello = ipc.recv().split(" ")
let seg = ipc.shm_open(to_int(hello[0]))
let parent = to_int(hello[1])
print("ipckid: saw", ipc.shm_read(seg[0], 0, 15), "in", seg[1], "shared bytes")
ipc.shm_write(seg[0], 100, "kid!!")
ipc.shm_set(seg[0], 200, 1234567890123)
ipc.send(parent, "ready")
let n = 0
while true:
    let m = ipc.recv()
    if m == "stop":
        break
    ipc.send(parent, "pong " .. m)
    n += 1
print("ipckid: answered", n, "pings")
ipc.shm_close(seg[0])
