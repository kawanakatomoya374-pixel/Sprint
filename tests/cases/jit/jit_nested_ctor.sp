class P:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x + 1
        self.y = y + 2
    func add(self, o):
        return P(self.x + o.x, self.y + o.y)
    func plus(self, k):
        return P(k, k)
    func sum(self):
        return self.x + self.y

class Q:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y

let p = P(0, 0)
let d = P(1, 2)
let s = 0
for i in range(3000):
    p = p.add(d)
    s += p.sum() % 7
print(s, p.x, p.y)

# types change mid-loop: the guards inside the inlined constructor fail and the interpreter takes over
let f = P(0.5, 1)
let g = P(1, 2)
let t = 0.0
for i in range(600):
    if i == 300:
        g = P(1.5, 2.5)
    f = f.add(g)
    t += f.sum()
print(t, f.x, f.y)

# integer overflow inside the constructor's arithmetic (the guard fails in the inlined init, the error comes from the interpreter)
let big = P(9223372036854775790, 1)
let one = P(0, 0)
let u = 0
try:
    for i in range(2000):
        big = big.add(one)
        u += 1
catch e:
    print("overflow after", u, big.x)

# an error raised from inside the inlined constructor reports the same call chain
class R:
    let v = 0
    func init(self, a):
        self.v = a // 1
    func mk(self, k):
        return R(k)
let r = R(1)
let z = 0
for i in range(50):
    z += r.mk(i + 1).v
print(z)
try:
    for i in range(50):
        z += r.mk(1 - i).v
        z += r.mk(0 * i).v
catch e:
    print("caught", z)

# a guard fails inside the constructor that an inlined method inlined: both frames must exist for the trace
class T:
    let a = 0
    let b = 0
    func init(self, a, b):
        self.a = a + 1
        self.b = b + 2
    func sum(self):
        return self.a + self.b
    func mk(self, x, y):
        return T(x, y)
let o = T(1, 1)
let w = 0
try:
    for i in range(1000):
        o = o.mk(i % 5, 1)
        w = w + o.sum() % 7
        if i == 400:
            o = o.mk(1.5, 2.5)
        if i == 600:
            o = o.mk(9223372036854775807, 2)
catch e:
    print("caught", e.kind, w)
print(w, o.a, o.b)
