let t = {}
for i in range(1500000):
    t[i * 7] = i
let s = 0
for i in range(1500000):
    s += t[i * 7]
for r in range(3):
    let u = {}
    for i in range(300000):
        u["k" .. to_string(i)] = i
    s += len(u)
print(s, len(t))
