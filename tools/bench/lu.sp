import math
func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func lu(a, n):
    for k in range(n):
        let rk = a[k]
        let piv = rk[k]
        for i in range(k + 1, n):
            let ri = a[i]
            let f = ri[k] / piv
            ri[k] = f
            for j in range(k + 1, n):
                ri[j] -= f * rk[j]
let n = 520
let a = []
let seed = 5
for i in range(n):
    let row = fill(n, 0.0)
    for j in range(n):
        seed = (seed * 16807) % 2147483647
        row[j] = seed / 2147483647.0 + (4.0 if i == j else 0.0)
    a.append(row)
lu(a, n)
let tr = 0.0
for i in range(n):
    tr += a[i][i]
print(math.floor(tr * 100000))
