# sysbench: starts 4 copies of sysspin and times them: with a kernel lock, system-call-heavy work does not speed up with more CPUs; with per-CPU kernels it does
import psys as sys
let t0 = sys.ms()
let ids = []
for i in range(4):
    ids.append(sys.spawn("sysspin"))
for id in ids:
    sys.wait(id)
print("sysbench: 4 x 60000 system calls took", sys.ms() - t0, "ms")
