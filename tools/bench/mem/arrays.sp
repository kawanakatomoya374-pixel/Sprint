let rows = []
for i in range(1500):
    let r = []
    for j in range(2000):
        r.append(i * j % 1000)
    rows.append(r)
let s = 0
for k in range(400000):
    let t = [k, k + 1, k + 2, k + 3]
    s += t[2]
for r in rows:
    for x in r:
        s += x
print(s, len(rows))
