# values the caller still has pending below an inlined construction (a local, a constant, a field read) while a guard inside the
# constructor fails without an error: the interpreter must continue the caller's expression with the right operands
class P:
    let v = 0
    func init(self, a):
        self.v = a + 1

class Q:
    let x = 0
    let y = 0
    func init(self, a, b):
        self.x = a * 2
        self.y = b - a
    func sum(self):
        return self.x + self.y

func fn_local(n):
    let t = 0
    for i in range(n):
        let a = i * 3
        let arg = i
        if i % 500 == 499:
            arg = i + 0.5
        t += a + P(arg).v
    return t
print(fn_local(3000))

# the pending operand is the loop variable itself, on the right and on the left
func fn_loopvar(n):
    let t = 0
    for i in range(n):
        let arg = i
        if i % 400 == 399:
            arg = 1.5
        t += i + P(arg).v
        t -= P(arg).v - i
    return t
print(fn_loopvar(3000))

# a constant below the construction
func fn_const(n):
    let t = 0
    for i in range(n):
        let arg = i
        if i % 300 == 299:
            arg = 0.25
        t += 7 + P(arg).v
    return t
print(fn_const(3000))

# a field read below the construction
func fn_field(n):
    let q = Q(1, 2)
    let t = 0
    for i in range(n):
        let a = i
        let b = 5
        if i % 250 == 249:
            a = 0.5
        t += q.x + Q(a, b).sum()
    return t
print(fn_field(3000))

# module level, two pending operands
let m = 0
for i in range(3000):
    let a = i
    let b = i + 1
    if i % 333 == 332:
        b = 0.5
    m = m + (a - (i + Q(a, b).sum()))
print(m)

# the same through a method that is inlined, with a construction inside it
class W:
    let k = 0
    func init(self, k):
        self.k = k
    func mk(self, d):
        return Q(self.k, d)
func fn_method(n):
    let w = W(3)
    let t = 0
    for i in range(n):
        let d = i
        if i % 200 == 199:
            d = 2.5
        t += i + w.mk(d).sum()
    return t
print(fn_method(3000))
