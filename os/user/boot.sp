# the boot program: starts the desktop and powers the machine off when it ends
import psys as sys
let d = sys.spawn("desktop")
print("boot: desktop is pid", d)
print("boot: desktop exited with", sys.wait(d))
