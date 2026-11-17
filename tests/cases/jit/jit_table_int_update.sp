# t[k] = t[k] + 1 with integer keys (the store reuses the lookup of the read), with deletions and growth in between
let t = {}
let x = 1
let hits = 0
for i in range(30000):
    x = (x * 16807) % 2147483647
    let k = x % 701
    let v = t[k]
    if v == nil:
        t[k] = i
    else:
        hits += 1
        t[k] = v + 1
    if i % 997 == 0:
        t[k] = nil
    if i % 5000 == 0:
        for j in range(100):
            t[100000 + j] = j
let s = 0
for k, v in t:
    s += v % 13
print(hits, len(t), s)
let u = {}
for i in range(20000):
    let k = i % 50
    u[k] = (u[k] ?? 0) + 1
    if i == 10000:
        delete(u, 7)
print(len(u), u[7], u[8])
