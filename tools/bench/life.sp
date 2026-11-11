func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func step(g, w, hh):
    let nxt = []
    for y in range(hh):
        let row = fill(w, 0)
        let up = g[(y + hh - 1) % hh]
        let cur = g[y]
        let dn = g[(y + 1) % hh]
        for x in range(w):
            let l = (x + w - 1) % w
            let r = (x + 1) % w
            let n = up[l] + up[x] + up[r] + cur[l] + cur[r] + dn[l] + dn[x] + dn[r]
            if n == 3 or (n == 2 and cur[x] == 1):
                row[x] = 1
        nxt.append(row)
    return nxt
let w = 128
let h = 128
let g = []
let seed = 7
for y in range(h):
    let row = []
    for x in range(w):
        seed = (seed * 16807) % 2147483647
        row.append(1 if seed % 3 == 0 else 0)
    g.append(row)
for i in range(300):
    g = step(g, w, h)
let alive = 0
for y in range(h):
    for x in range(w):
        alive += g[y][x]
print(alive)
