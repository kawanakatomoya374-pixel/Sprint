# Objects in an array, a method that returns nil called as a statement, and data-dependent branches (several path variants).
class P:
    let x = 0.0
    let v = 0.0
    func init(self, x, v):
        self.x = x
        self.v = v
    func step(self, dt):
        self.x += self.v * dt
        if self.x < 0.0 or self.x > 10.0:
            self.v = 0.0 - self.v

let ps = []
for i in range(300):
    ps.append(P((i % 10) * 1.0, (i % 7) - 3.0))
for r in range(200):
    for p in ps:
        p.step(0.25)
let s = 0.0
let m = 0.0
for p in ps:
    s += p.x
    if p.v > m:
        m = p.v
print(to_int(s * 1000), m)
