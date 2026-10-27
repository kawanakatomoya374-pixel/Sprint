# Fused-opcode fast paths and their fallbacks (ints, floats, overflow, mixed types).
func ints(n):
    let s = 0
    let i = 0
    while i < n:
        s = s + i * 2 - 1
        i = i + 1
    return s
func floats(n):
    let s = 0.5
    let i = 0.0
    while i < n:
        s = s + i
        i = i + 1.5
    return s
func mixed(a, b):
    let r = []
    r.append(a + 1)
    r.append(a - b)
    r.append(a * 3)
    r.append(a < b)
    r.append(a == 2)
    r.append(a % 5)
    return r
func edges(x):
    let y = x + 1
    return y
func cmpjump(a, b):
    if a < b:
        return "lt"
    if a >= b:
        return "ge"
    return "?"
print(ints(1000))
print(floats(10))
print(mixed(7, 3))
print(mixed(7.5, 3))
print(mixed(7, 3.5))
print(cmpjump(1, 2), cmpjump(2, 2), cmpjump(1.5, 1), cmpjump("a", "b"))
try:
    print(edges(9223372036854775807))
catch e:
    print(e.kind, e.message)
try:
    print(edges("x"))
catch e:
    print(e.kind)
let big = 9223372036854775806
try:
    let k = big
    k = k + 1
    print(k)
    k = k + 1
    print(k)
catch e:
    print(e.kind)
let t = 0
for i in range(10, 0, -3):
    t += i
print(t)
for i in range(3):
    let q = i
    q = q - 1
    print(q)
print(-7 % 3, 7 % -3, 7 % 3)
# --- more fused shapes ---
class Pt:
    let x = 0
    let y = 0
    func init(self, x, y):
        self.x = x
        self.y = y
    func sum(self):
        return self.x + self.y
func getx(p):
    return p.x
func idx(a, i):
    return a[i]
func retl(v):
    return v
let p = Pt(3, 4)
print(getx(p), p.sum(), idx([5, 6, 7], 2), idx("abc", 1), retl(nil), retl(2.5))
try:
    print(idx([1], 3))
catch e:
    print(e.kind)
try:
    print(getx(5))
catch e:
    print(e.kind)
let acc = 0
let facc = 0.5
for i in range(1000):
    acc = acc + i
    facc = facc + 0.5
print(acc, facc)
let w = 0
let k = 0
while k < 10:
    w = w - k
    k = k + 1
print(w, k)
let mm = 0
for i in range(-5, 12):
    mm += i % 4 + i % 8 + i % 3
print(mm)
let ov = 9223372036854775800
try:
    for i in range(20):
        ov = ov + 1
catch e:
    print(e.kind, ov)
func nested(n):
    let c = 0
    for i in range(n):
        for j in range(n):
            if i < j:
                c += 1
    return c
print(nested(30))
