# the boot program: starts the file system server, the GPU server and the GUI server, and powers the machine off when the GUI ends
import psys as sys
import ipc
let fsd = sys.spawn("fsd")
print("boot: fsd is pid", fsd)
let gpud = sys.spawn("gpud")
print("boot: gpud is pid", gpud)
let inputd = sys.spawn("inputd")
print("boot: inputd is pid", inputd)
let d = sys.spawn("guid")
print("boot: guid is pid", d)
print("boot: guid exited with", sys.wait(d))
ipc.send(fsd, "quit")
ipc.send(gpud, "quit")
ipc.send(inputd, "quit")
print("boot: fsd exited with", sys.wait(fsd))
print("boot: gpud exited with", sys.wait(gpud))
print("boot: inputd exited with", sys.wait(inputd))
