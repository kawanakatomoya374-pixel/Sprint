func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
import math
func a(i, j):
    return 1.0 / ((i + j) * (i + j + 1) // 2 + i + 1)
func mul_av(n, v, out):
    for i in range(n):
        let s = 0.0
        for j in range(n):
            s += a(i, j) * v[j]
        out[i] = s
func mul_atv(n, v, out):
    for i in range(n):
        let s = 0.0
        for j in range(n):
            s += a(j, i) * v[j]
        out[i] = s
func mul_atav(n, v, out, tmp):
    mul_av(n, v, tmp)
    mul_atv(n, tmp, out)
let n = 1500
let u = fill(n, 1.0)
let v = fill(n, 0.0)
let tmp = fill(n, 0.0)
for i in range(10):
    mul_atav(n, u, v, tmp)
    mul_atav(n, v, u, tmp)
let vbv = 0.0
let vv = 0.0
for i in range(n):
    vbv += u[i] * v[i]
    vv += v[i] * v[i]
print(math.floor(math.sqrt(vbv / vv) * 1000000000))
