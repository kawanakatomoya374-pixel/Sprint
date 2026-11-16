# a function compiled from its entry containing for-in loops (FOR_PREP) over arrays of instances: the element class is guarded where the
# element is stored into a local; other iterables, mixed classes, empty arrays and changing arrays must behave as in the interpreter
class P:
    let x = 0.0
    let v = 0.0
    func init(self, x, v):
        self.x = x
        self.v = v
class Q:
    let x = 0.0
    let v = 0.0
    let w = 1.0
    func init(self, x, v):
        self.x = x
        self.v = v
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
func total(bs):
    let s = 0.0
    for b in bs:
        s += b.x + b.v
    return s
func count_pairs(xs, ys):
    let n = 0
    for a in xs:
        for b in ys:
            if a < b:
                n += 1
    return n
func sum_table(t):
    let s = 0
    for k, v in t:
        s += v
    return s
let ps = [P(1.0, 0.5), P(2.0, -0.25), P(3.0, 0.125), P(4.0, 1.0)]
for r in range(400):
    step(ps, 0.01)
print(to_int(total(ps) * 1000000))
# the same function with another class, an empty array and a mixed one
let qs = [Q(1.0, 0.5), Q(2.5, -0.5), Q(0.5, 0.0)]
for r in range(400):
    step(qs, 0.01)
print(to_int(total(qs) * 1000000))
print(total([]), to_int(total([P(1.0, 2.0)]) * 10))
let mixed = [P(1.0, 1.0), Q(2.0, 2.0), P(3.0, 3.0)]
let tm = 0.0
for r in range(300):
    tm += total(mixed)
print(to_int(tm))
# other iterables
let nums = [1, 2, 3, 4, 5, 6]
let cp = 0
for r in range(300):
    cp += count_pairs(nums, [3, 4, 9])
print(cp)
let tb = {a: 1, b: 2, c: 3}
let ts = 0
for r in range(300):
    ts += sum_table(tb)
print(ts)
