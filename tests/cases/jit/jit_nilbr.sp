# `x ?? y`, `x == nil`, `x != nil` and `not (x == nil)` in compiled code: nil, false, 0 and empty values, and operands that change kind
func dflt(a, b):
    return a ?? b
func count(t, k):
    t[k] = (t[k] ?? 0) + 1
func isnil(a):
    if a == nil:
        return 1
    return 0
func notnil(a):
    if a != nil:
        return 1
    return 0
func notis(a):
    if not (a == nil):
        return 1
    return 0
func typed_known(n):
    let s = 0
    let f = 1.5
    for i in range(n):
        if i != nil:
            s += 1
        if f == nil:
            s += 100
        if (i + 1) == nil:
            s += 1000
    return s
func run(n):
    let t = {}
    let keys = ["x", "y", "z"]
    let vals = [nil, false, 0, 0.0, "", [], 7, 2.5, true]
    let s = 0
    for i in range(n):
        count(t, keys[i % 3])
        let v = vals[i % 9]
        s += isnil(v) * 3 + notnil(v) * 5 + notis(v) * 7
        let d = dflt(v, 11)
        if d == 11:
            s += 13
        if dflt(v, nil) == nil:
            s += 17
    return [t, s]
print(run(900))
print(dflt(nil, 1), dflt(false, 1), dflt(0, 1), dflt("", 1), dflt(nil, nil))
print(isnil(nil), isnil(false), notnil(nil), notnil(0), notis(nil), notis([]))
print(typed_known(500))
# the second operand type changes after the code is hot
let t2 = {}
for i in range(400):
    t2[i % 5] = (t2[i % 5] ?? 0) + i
print(t2)
let q = [nil, 1, nil, 2]
let q2 = [5, 5, 5, 5]
let tot = 0
for i in range(800):
    let e = q[i % 4]
    if e != nil:
        tot += e
    if i == 400:
        q = q2
print(tot)
