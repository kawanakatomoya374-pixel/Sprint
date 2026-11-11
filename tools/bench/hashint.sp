let t = {}
let x = 1
let hits = 0
for i in range(2000000):
    x = (x * 16807) % 2147483647
    let k = x % 600011
    let v = t[k]
    if v == nil:
        t[k] = i
    else:
        hits += 1
        t[k] = v + 1
let s = 0
for k, v in t:
    s += v % 7
print(hits, len(t), s)
