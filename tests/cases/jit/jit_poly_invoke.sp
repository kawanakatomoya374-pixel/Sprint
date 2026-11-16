# a method call on receivers of several classes (a polymorphic call site): the region is recompiled with a per-site class cache.
# six classes overflow the four-entry cache, one receiver holds a function in a field, and the GC runs between the loops.
import gc
class Base:
    let n = 0
    func init(self, n):
        self.n = n
    func f(self, x):
        return x
class A extends Base:
    override func f(self, x):
        self.n += 1
        return (x * 3 + 1) % 1009
class B extends Base:
    override func f(self, x):
        self.n += 2
        return (x + self.n) % 1013
class C extends Base:
    override func f(self, x):
        self.n += 3
        return (x * 5 + 7) % 1019
class D extends Base:
    override func f(self, x):
        self.n += 1
        return x ^ 21
class E extends Base:
    override func f(self, x):
        return (x + 11) % 997
class F extends Base:
    override func f(self, x):
        self.n -= 1
        return (x * 2 + self.n) % 1021
class G:
    let f = nil
    func init(self):
        self.f = func(x): x + 100
let objs = []
for i in range(30):
    let k = i % 6
    if k == 0:
        objs.append(A(i))
    elif k == 1:
        objs.append(B(i))
    elif k == 2:
        objs.append(C(i))
    elif k == 3:
        objs.append(D(i))
    elif k == 4:
        objs.append(E(i))
    else:
        objs.append(F(i))
func run(objs, rounds):
    let v = 1
    let acc = 0
    for r in range(rounds):
        for o in objs:
            v = o.f(v)
            acc += v
        if r % 500 == 0:
            gc.collect()
    return acc
print(run(objs, 3000), objs[0].n, objs[1].n, objs[2].n, objs[5].n)
let mixed = [A(1), G(), B(2), G(), C(3)]
let s = 0
let w = 1
for r in range(2000):
    for o in mixed:
        w = o.f(w) % 5000
        s += w
print(s, mixed[0].n)
