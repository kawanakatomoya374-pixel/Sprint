let a = []
for i in range(400000):
    a.append("item-" .. to_string(i))
let n = 0
for r in range(4):
    for i in range(200000):
        let t = "tmp" .. to_string(i) .. "-" .. to_string(r)
        n += len(t)
for s in a:
    n += len(s)
print(n, len(a))
