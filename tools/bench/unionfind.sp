func fill(n, v):
    let a = []
    a.reserve(n)
    for i in range(n):
        a.append(v)
    return a
func find(p, x):
    let r = x
    while p[r] != r:
        r = p[r]
    while p[x] != r:
        let nx = p[x]
        p[x] = r
        x = nx
    return r
let n = 800000
let p = fill(n, 0)
let sz = fill(n, 1)
for i in range(n):
    p[i] = i
let seed = 11
let comps = n
for i in range(1500000):
    seed = (seed * 16807) % 2147483647
    let a = seed % n
    seed = (seed * 16807) % 2147483647
    let b = seed % n
    let ra = find(p, a)
    let rb = find(p, b)
    if ra != rb:
        if sz[ra] < sz[rb]:
            let t = ra
            ra = rb
            rb = t
        p[rb] = ra
        sz[ra] += sz[rb]
        comps -= 1
print(comps)
