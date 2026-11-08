class P:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
    func len2(self):
        return self.x * self.x + self.y * self.y
    func bump(self, d):
        self.x = self.x + d
        return self.x
    func pick(self):
        if self.x > 10:
            return 1
        return 2
class Q:
    let x = 5
    let y = 6
    func len2(self):
        return self.x + self.y
    func bump(self, d):
        return d
let p = P(3, 4)
let q = Q()
let s = 0
for i in range(100000):
    s += p.len2() % 7
    s += p.bump(1) % 3
print(s)
let o = p
let t = 0
for i in range(100000):
    if i == 60000:
        o = q
    t += o.len2() % 11
print(t)
let u = 0
for i in range(100000):
    u += p.pick()
print(u)
