# the boot program: starts the file system server and the GUI server, and powers the machine off when the GUI ends
import psys as sys
import ipc
let fsd = sys.spawn("fsd")
print("boot: fsd is pid", fsd)
let d = sys.spawn("guid")
print("boot: guid is pid", d)
print("boot: guid exited with", sys.wait(d))
ipc.send(fsd, "quit")
print("boot: fsd exited with", sys.wait(fsd))
