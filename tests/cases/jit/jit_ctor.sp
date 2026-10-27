# Constructors whose init body is compiled into the caller: results, errors raised inside init and a collection while
# objects are being built must all equal the interpreter's.
class P:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
class Q:
    let a = 0
    let b = 1.5
    func init(self, a):
        self.a = a * 2
        self.b = self.b + a
class Z:
    let v = 7
class R:
    let n = nil
    let k = 0
    func init(self, n):
        self.n = n
        self.k = 3

func build(n):
    let s = 0
    let f = 0.0
    for i in range(n):
        let p = P(i, i + 1)
        let q = Q(i)
        let z = Z()
        let r = R(p)
        s = s + p.x + p.y + q.a + z.v + r.k + r.n.y
        f = f + q.b
    return [s, f]
print(build(2000))

func ovf(n, big):
    let s = 0
    for i in range(n):
        let q = Q(big)
        s = s + q.a
    return s
try:
    print(ovf(50, 4611686018427387904))
catch e:
    print("caught", e.kind)
print(ovf(50, 5))

func keep(n):
    let xs = []
    for i in range(n):
        xs.append(P(i, i * 2))
    let t = 0
    for p in xs:
        t = t + p.x + p.y
    return t
print(keep(3000))

func mixed(n):
    let t = 0
    for i in range(n):
        let p = P(1.5, "s")
        let q = P(i, nil)
        t = t + (q.x if q.y == nil else 0)
        if p.y != "s":
            t = -1
    return t
print(mixed(500))
