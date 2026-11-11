func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func sor(g, n, iters, omega):
    let o4 = omega * 0.25
    let om = 1.0 - omega
    for p in range(iters):
        for i in range(1, n - 1):
            let gi = g[i]
            let gim = g[i - 1]
            let gip = g[i + 1]
            for j in range(1, n - 1):
                gi[j] = o4 * (gim[j] + gip[j] + gi[j - 1] + gi[j + 1]) + om * gi[j]
let n = 300
let g = []
for i in range(n):
    let row = fill(n, 0.0)
    for j in range(n):
        row[j] = ((i * 7 + j * 3) % 11) / 11.0
    g.append(row)
sor(g, n, 100, 1.25)
let s = 0.0
for i in range(n):
    for j in range(n):
        s += g[i][j]
print(to_string(s).slice(0, 8))
