import coroutine
class Plain:
    let a = 1
    let b = "s"
    let c = nil
    let d = true
    let e = 2.5
    let f = -7
class Arr:
    let xs = []
    let n = 3
class Defaults:
    let v = 0
    func init(self, a, b = 10, ...rest):
        self.v = a + b + len(rest)
class Child extends Defaults:
    let w = 5
    override func init(self, a):
        super(a, 1)
        self.w += a
class Reassign:
    let v = 1
    func init(self):
        self = nil
        self.v = 2
class Boom:
    func init(self, x):
        throw error("InitError", "bad " .. to_string(x))
let p = Plain()
print(p.a, p.b, p.c, p.d, p.e, p.f)
let a1 = Arr()
let a2 = Arr()
a1.xs.append(1)
print(a1.xs, a2.xs, a1.n)
print(Defaults(1).v, Defaults(1, 2).v, Defaults(1, 2, 3, 4).v)
let c = Child(4)
print(c.v, c.w, is_instance(c, Defaults))
try:
    Plain(1)
catch e:
    print(e.kind, e.message)
try:
    Defaults()
catch e:
    print(e.kind)
try:
    Boom(7)
catch e:
    print(e.kind, e.message)
try:
    Reassign()
catch e:
    print(e.kind)
print([1, 2, 3].map(func(x): Child(x)).map(func(o): o.w))
print(len([1, 2].map(func(x): Plain())))
func gen():
    let r = Defaults(2)
    yield r.v
    yield Child(1).v
let co = coroutine.create(gen)
print(coroutine.resume(co), coroutine.resume(co))
let keep = []
for i in range(20000):
    let q = Defaults(i)
    if i % 5000 == 0:
        keep.append(q)
print(len(keep), keep[3].v)
print(classof(Plain()) == Plain, type(Plain()))
