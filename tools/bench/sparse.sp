import math
func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
let n = 4000
let per = 12
let val = []
let col = []
let rowp = [0]
let seed = 3
for i in range(n):
    for j in range(per):
        seed = (seed * 16807) % 2147483647
        col.append(seed % n)
        val.append((seed % 1000) / 1000.0)
    rowp.append(len(col))
let x = fill(n, 1.0)
let y = fill(n, 0.0)
for r in range(900):
    for i in range(n):
        let s = 0.0
        for p in range(rowp[i], rowp[i + 1]):
            s += val[p] * x[col[p]]
        y[i] = s
    for i in range(n):
        x[i] = y[i] / (1.0 + y[i] * 0.0001)
let t = 0.0
for i in range(n):
    t += x[i]
print(math.floor(t * 1000))
