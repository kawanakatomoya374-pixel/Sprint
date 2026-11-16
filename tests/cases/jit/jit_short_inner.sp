# an inner loop that runs only a few iterations per entry is handed back from the TraceJIT to the region JIT (entering a trace
# costs more than it earns), and the enclosing region is compiled again with the loop in it: results must not change.
class P:
    let x = 0.0
    let v = 0.0
    func init(self, x, v):
        self.x = x
        self.v = v
let ps = [P(1.0, 0.5), P(2.0, -0.25), P(3.0, 0.125), P(4.0, 1.0), P(5.0, -1.0)]
func step(bs, dt):
    let n = len(bs)
    for i in range(n):
        let a = bs[i]
        for j in range(i + 1, n):
            let b = bs[j]
            let d = a.x - b.x
            let f = dt * d / (1.0 + d * d)
            a.v -= f
            b.v += f
    for b in bs:
        b.x += dt * b.v
for r in range(30000):
    step(ps, 0.01)
print(to_int(ps[0].x * 1000000), to_int(ps[4].v * 1000000))
# the same loop shape with the count of the inner loop growing: first short, then long
func tri(n, rounds):
    let s = 0
    for r in range(rounds):
        for i in range(n):
            s += i * r % 7
    return s
print(tri(2, 20000), tri(40, 3000), tri(3, 20000), tri(200, 1000))
