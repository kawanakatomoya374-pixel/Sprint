# A short traced inner loop inside a hot outer loop whose body the region JIT cannot compile on its own (objects taken from an array).
class B:
    let x = 0.0
    let v = 0.0
    func init(self, x, v):
        self.x = x
        self.v = v
func step(bs, dt):
    let n = len(bs)
    for i in range(n):
        let bi = bs[i]
        for j in range(i + 1, n):
            let bj = bs[j]
            let d = bi.x - bj.x
            bi.v -= d * dt
            bj.v += d * dt
    for b in bs:
        b.x += b.v * dt
let bs = []
for k in range(6):
    bs.append(B(k * 1.5, 0.0))
for r in range(4000):
    step(bs, 0.001)
let s = 0.0
for b in bs:
    s += b.x * 3.0 + b.v
print(to_int(s * 1000000))
