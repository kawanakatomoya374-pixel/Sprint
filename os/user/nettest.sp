# nettest: starts the network card driver and lets it run for a few seconds (the QEMU test os-net-test runs this as the init program).
import psys as sys
import ipc
let n = sys.spawn("netd")
sys.sleep_ms(3000)
let pid = ipc.lookup("net")
ipc.send(pid, "stats")
print("nettest: stats", ipc.recv())
ipc.send(pid, "quit")
sys.wait(n)
print("nettest: done")
