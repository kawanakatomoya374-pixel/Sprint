let counts = {}
let seed = 31
for i in range(2000000):
    seed = (seed * 16807) % 2147483647
    let k = seed % 256
    counts[k] = (counts[k] ?? 0) + 1
let mx = 0
let arg = 0
for k, v in counts:
    if v > mx:
        mx = v
        arg = k
print(len(counts), mx, arg)
