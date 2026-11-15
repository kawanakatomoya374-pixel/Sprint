import math
func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
let n = 100000
let xs = fill(n, 0.0)
let ys = fill(n, 0.0)
let zs = fill(n, 0.0)
for i in range(n):
    xs[i] = (i % 100) * 0.5
    ys[i] = (i % 37) * 0.25
    zs[i] = (i % 11) * 1.5
for r in range(400):
    let c = math.cos(r * 0.05)
    let s = math.sin(r * 0.05)
    for i in range(n):
        let x = xs[i]
        let y = ys[i]
        let z = zs[i]
        xs[i] = x * c - y * s
        ys[i] = x * s + y * c
        zs[i] = z * 0.999 + x * 0.001
let t = 0.0
for i in range(n):
    t += xs[i] + ys[i] * 2.0 + zs[i] * 3.0
print(math.floor(t * 10))
