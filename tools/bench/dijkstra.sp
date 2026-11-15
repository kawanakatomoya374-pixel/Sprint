func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
let n = 250000
let deg = 5
let to = []
let wt = []
let seed = 7
for u in range(n):
    for k in range(deg):
        seed = (seed * 16807) % 2147483647
        to.append(seed % n)
        wt.append(1 + seed % 100)
let dist = fill(n, 1000000000)
let hk = fill(n * deg + 1, 0)
let hv = fill(n * deg + 1, 0)
let hn = 0
func push(k, v):
    let i = hn
    hn += 1
    while i > 0:
        let p = (i - 1) // 2
        if hk[p] <= k:
            break
        hk[i] = hk[p]
        hv[i] = hv[p]
        i = p
    hk[i] = k
    hv[i] = v
dist[0] = 0
push(0, 0)
let pops = 0
while hn > 0:
    let k = hk[0]
    let u = hv[0]
    hn -= 1
    let lk = hk[hn]
    let lv = hv[hn]
    let i = 0
    while true:
        let c = 2 * i + 1
        if c >= hn:
            break
        if c + 1 < hn and hk[c + 1] < hk[c]:
            c += 1
        if hk[c] >= lk:
            break
        hk[i] = hk[c]
        hv[i] = hv[c]
        i = c
    hk[i] = lk
    hv[i] = lv
    pops += 1
    if k > dist[u]:
        continue
    for e in range(u * deg, u * deg + deg):
        let v = to[e]
        let nd = k + wt[e]
        if nd < dist[v]:
            dist[v] = nd
            push(nd, v)
let s = 0
for i in range(n):
    if dist[i] < 1000000000:
        s += dist[i]
print(s, pops)
