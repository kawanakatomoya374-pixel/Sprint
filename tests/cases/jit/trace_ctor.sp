class P:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
    func add(self, o):
        return P(self.x + o.x, self.y + o.y)
    func len2(self):
        return self.x * self.x + self.y * self.y
let p = P(0, 0)
let d = P(1, 2)
let s = 0
for i in range(200000):
    p = p.add(d)
    s += p.len2() % 3
print(s)
print(p.x, p.y)
func many(n):
    let keep = []
    let q = P(1, 1)
    for i in range(n):
        q = P(i, i + 1)
        if i % 1000 == 0:
            keep.append(q)
    return len(keep) * 1000 + q.y
print(many(300000))
func fl(n):
    let q = P(0.5, 1)
    let t = 0
    for i in range(n):
        q = P(i, 2)
        t += q.x + q.y
    return t
print(fl(100000))
