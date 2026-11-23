# sysspin: a process that makes system calls as fast as it can (each one runs the kernel's Sprint code), for the kernel scaling benchmark
import psys as sys
let n = 0
let t0 = sys.ms()
while n < 60000:
    sys.pid()
    n += 1
