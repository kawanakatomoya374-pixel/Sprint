class P:
    let x = 0.0
    let y = 0.0
    let vx = 0.0
    let vy = 0.0
    func init(self, x, y, vx, vy):
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
    func step(self, dt):
        self.x += self.vx * dt
        self.y += self.vy * dt
        if self.x < 0.0 or self.x > 100.0:
            self.vx = 0.0 - self.vx
        if self.y < 0.0 or self.y > 100.0:
            self.vy = 0.0 - self.vy
let ps = []
let seed = 41
for i in range(5000):
    seed = (seed * 16807) % 2147483647
    let a = (seed % 1000) / 10.0
    seed = (seed * 16807) % 2147483647
    let b = (seed % 1000) / 10.0
    ps.append(P(a, b, (seed % 7) - 3.0, (seed % 5) - 2.0))
for r in range(600):
    for p in ps:
        p.step(0.1)
let sx = 0.0
let sy = 0.0
for p in ps:
    sx += p.x
    sy += p.y
print(to_int(sx * 100), to_int(sy * 100))
