# module variables read and written through registers in compiled loops (LOAD_MODULE / STORE_MODULE)
let a = 0
let b = 1
let f = 0.5
let g = 1.5
let s = 0
for i in range(5000):
    a = a + b
    b = b + 2
    f = f * 1.0001 + g
    s += (a * 3 + b) % 7
print(a, b, f, s)

# swaps and reads of the old value inside one statement
let x = 1
let y = 2
for i in range(3001):
    let t = x
    x = y
    y = (t + y) % 1000003
print(x, y)
let p = 10
let q = 20
for i in range(1000):
    p = (q - p) % 1000003
    q = (p + q) % 1000003
print(p, q)

# overflow leaves for the interpreter: the variable keeps its old value, the error is the same
let big = 9223372036854775000
let inc = 100
let n = 0
try:
    for i in range(100):
        big = big + inc
        n += 1
catch e:
    print("overflow", n, big)

# the type of a module variable changes mid-loop (int -> float -> string)
let v = 0
let w = 0
for i in range(3000):
    if i == 1000:
        v = 1.5
    if i == 2000:
        v = "s"
    if i < 2000:
        w = w + v
    else:
        w = w + 1
print(v, w)

# a float variable receiving ints and ints receiving floats
let m = 0.0
let k = 1
for i in range(2000):
    m = m + k
    if i == 1500:
        k = 0.25
print(m, k)

# instances held in module variables, read and written in the loop
class Pt:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
    func add(self, o):
        return Pt(self.x + o.x, self.y + o.y)
let pt = Pt(0, 0)
let dd = Pt(1, 2)
let tot = 0
for i in range(3000):
    pt = pt.add(dd)
    tot += pt.x + pt.y
print(tot, pt.x, pt.y)

# values kept in a register across a call that changes the variable
let cnt = 0
func bump():
    cnt = cnt + 1
    return cnt
let acc = 0
for i in range(1000):
    acc = acc + cnt + bump()
print(acc, cnt)

# nested loops with the same variable on both levels
let u = 0
for i in range(100):
    for j in range(100):
        u = u + i * j
        u = u - 1
print(u)
