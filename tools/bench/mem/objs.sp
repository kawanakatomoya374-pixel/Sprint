class V:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
let live = []
for i in range(600000):
    live.append(V(i, i + 1))
let s = 0
for r in range(6):
    for i in range(500000):
        let t = V(i, r)
        s += t.x + t.y
for v in live:
    s += v.y
print(s, len(live))
