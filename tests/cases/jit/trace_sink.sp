class P:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
    func add(self, o):
        return P(self.x + o.x, self.y + o.y)
    func scale(self, k):
        return P(self.x * k, self.y * k)
func run(n):
    let p = P(0, 0)
    let d = P(1, 2)
    for i in range(n):
        p = p.add(d)
    return p
let r = run(100000)
print(r.x, r.y)
func early(n):
    let p = P(1, 1)
    for i in range(n):
        p = p.add(p)
        if i == 40:
            break
    return p
let e = early(1000)
print(e.x, e.y)
func overflowish(n):
    let p = P(1, 1)
    for i in range(n):
        p = p.scale(3)
    return p
let o = overflowish(30)
print(o.x, o.y)
func keeper(n):
    let p = P(0, 0)
    let d = P(2, 3)
    let saved = []
    for i in range(n):
        p = p.add(d)
        if i % 5000 == 0:
            saved.append(p)
    return saved
let sv = keeper(40000)
print(len(sv), sv[0].x, sv[1].y, sv[7].x)
func mixed(n):
    let p = P(0, 0)
    let d = P(1, 1)
    for i in range(n):
        if i == 60000:
            d = P(0.5, 2)
        p = p.add(d)
    return p
let m = mixed(100000)
print(m.x, m.y)
func modvar():
    let t = 0
    for i in range(50000):
        t += P(i, 1).x % 3
    return t
print(modvar())
