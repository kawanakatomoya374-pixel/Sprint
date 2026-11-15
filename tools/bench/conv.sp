import math
func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
let n = 200000
let k = 33
let x = fill(n, 0.0)
let h = fill(k, 0.0)
for i in range(n):
    x[i] = math.sin(i * 0.01) + (i % 7) * 0.1
for j in range(k):
    h[j] = math.exp(0.0 - j * 0.1) / 10.0
let y = fill(n, 0.0)
for r in range(30):
    for i in range(k, n):
        let s = 0.0
        for j in range(k):
            s += h[j] * x[i - j]
        y[i] = s
let t = 0.0
for i in range(n):
    t += y[i]
print(math.floor(t * 1000))
