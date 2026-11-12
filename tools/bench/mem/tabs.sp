let live = []
for i in range(150000):
    live.append({"id": i, "name": "n" .. to_string(i % 100), "v": i * 2})
let s = 0
let ring = []
for i in range(1024):
    ring.append(nil)
for r in range(4):
    for i in range(150000):
        let t = {"a": i, "b": r, "c": i + r}
        ring[i % 1024] = t
        s += t["a"] + t["c"]
for t in live:
    s += t["v"]
print(s, len(live))
