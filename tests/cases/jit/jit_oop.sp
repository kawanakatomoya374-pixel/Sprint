let g = 2
let live = 0
class A:
    let a = 7
    let b = 7
    let c = 7
    func init(self, a, b):
        self.a = a
        self.b = b
    func m0(self, n):
        self.a = (0.5 - (n - 2)) % 100003
        return ((3 - (n - 0.5)) + n)
    func m1(self, n):
        self.b = 1 % 100003
        self.b = (0.5 - (2 + n)) % 100003
        return 3
    func m2(self, n):
        return (self.m0(3) + (3 - 3))
    func m3(self, n):
        return (self.a * ((self.b - 3) + self.m2(0.5)))
    func spawn(self, n):
        return A(self.a + n, self.b)
class B extends A:
    let d = 3
    override func m3(self, n):
        return super.m3(n) * 2 + self.d
    override func m1(self, n):
        return super.m1(n) * 2 + self.d
    override func m2(self, n):
        return super.m2(n) * 2 + self.d
    override func m0(self, n):
        return super.m0(n) * 2 + self.d
let objs = [A(1, 2), B(3, 4), A(5, 6)]
let p = A(1, 1)
let q = B(2, 2)
let acc = 0
let facc = 0.0
let cnt = 0
for i in range(20):
    acc = (acc + q.m2(i % 5)) % 1000003
    p = p.spawn(i % 4)
    acc = (acc + p.m3(i % 5)) % 1000003
    acc = (acc + p.m0(i % 5)) % 1000003
    if i % 13 == 0:
        print(i, acc, facc, cnt, p.a, p.b, q.a, q.c)
print(acc, facc, cnt, p.a, q.a, objs[0].a, objs[1].b)
