# CPU-bound, never yields: only the timer interrupt lets the other worker run
import psys as sys
func spin(n):
    let s = 0
    for i in range(n):
        s += i % 7
    return s
let me = sys.pid()
let t0 = sys.ms()
let rounds = 0
while sys.ms() - t0 < 120:
    spin(20000)
    rounds += 1
print("worker", me, "ran", rounds, "rounds")
