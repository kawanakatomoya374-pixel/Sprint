import math
# math functions called from hot loops (TraceJIT calls libm / inlines): results and errors equal the interpreter's.
func trig(n):
    let s = 0.0
    for i in range(1, n):
        let x = i * 0.01
        s += math.sin(x) * math.cos(x) + math.exp(-x * 0.01) + math.tan(x * 0.001) + math.atan(x) + math.sqrt(x)
    return s
print(trig(5000))

func floors(n):
    let s = 0
    for i in range(-n, n):
        let x = i * 0.37 - 0.5
        s += math.floor(x) + math.floor(i) + math.floor(x * 1e6) % 7
    return s
print(floors(3000))

func absl(n):
    let s = 0.0
    for i in range(-n, n):
        s += math.abs(i * 0.25 - 1.0) + math.abs(-0.0)
    return s
print(absl(3000))

func logs(n):
    let s = 0.0
    for i in range(1, n):
        s += math.log(i * 0.5)
    return s
print(logs(4000))

func bad_log(n):
    let s = 0.0
    for i in range(n):
        s += math.log(i * 1.0 - 50.0 + 100.0 * 0.01)
    return s
try:
    print(bad_log(200))
catch e:
    print(e.kind)

func bad_sqrt(n):
    let s = 0.0
    for i in range(n):
        s += math.sqrt(100.0 - i)
    return s
try:
    print(bad_sqrt(200))
catch e:
    print(e.kind)

func big_floor(n):
    let s = 0
    for i in range(n):
        s += math.floor(1.0e15 * (i + 1) * 1000.0)
    return s
try:
    print(big_floor(100))
catch e:
    print(e.kind)

func mixed_ints(n):
    let s = 0.0
    for i in range(1, n):
        s += math.sqrt(i) + math.sin(i) + math.exp(0 - i % 5)
    return s
print(mixed_ints(3000))
