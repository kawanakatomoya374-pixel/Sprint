class P:
    let a = 0
    let b = 0
    func init(self, a, b):
        self.a = a
        self.b = b
let big = []
for i in range(2000000):
    big.append(P(i, i + 1))
let s = 0
for r in range(5):
    for i in range(1000000):
        let t = P(i, r)
        s += t.a
for p in big:
    s += p.b
print(s, len(big))
