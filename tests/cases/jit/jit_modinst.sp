class A:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
    func sum(self):
        return self.x + self.y
    func bump(self, d):
        return A(self.x + d.x, self.y + d.y)

class B:
    let x = 10
    let y = 20
    func init(self, x, y):
        self.x = x
        self.y = y
    func sum(self):
        return self.x * 2 + self.y
    func bump(self, d):
        return B(self.x + d.x, self.y + d.y)

let p = A(1, 2)
let q = A(3, 4)
let t = 0

# swapping module variables in a loop (pending reads of a variable must see its old value)
for i in range(1000):
    let tmp = p
    p = q
    q = tmp
    t += p.sum() * 3 + q.sum()
print(t, p.x, q.x)

# the class of a module variable changes mid-loop
let r = A(1, 1)
let d = A(1, 2)
for i in range(1000):
    if i == 400:
        r = B(1, 1)
        d = B(2, 3)
    r = r.bump(d)
    t += r.sum() % 11
print(t, r.x, r.y)

# a function (not inlinable: it loops) rebinds the variable
func rebind(k):
    let n = 0
    for j in range(k):
        n += j
    r = A(n, k)
    return n

for i in range(600):
    r = r.bump(d)
    if i % 100 == 99:
        t += rebind(i)
    t += r.sum() % 5
print(t, r.x, r.y)

# the same loop run again with the variable holding another class
func run(v, w):
    let s = 0
    for i in range(500):
        v = v.bump(w)
        s += v.sum() % 13
    return s

let va = A(1, 1)
let wa = A(1, 2)
let vb = B(1, 1)
let wb = B(2, 1)
print(run(va, wa), run(va, wa), run(vb, wb), run(va, wa), run(vb, wb))

# an uninitialised/other-typed variable at entry
let z = 5
for i in range(300):
    z = z + i
print(z)
