# f-strings
let name = "Sprint"
let n = 3
print(f"hello {name}! n={n} sum={n + 4}")
print(f"{{literal}} {n}")
print(f"{name}")
print(f"{[1, 2].map(func(x): x * 2)} {'q'} {len(name)}")
print(f"")
const t = {a: 1}
print(f"{t.a}-{t['a']}")
# slices
let a = [10, 20, 30, 40, 50]
print(a[1:3], a[:2], a[3:], a[:])
print("abcdef"[1:4], "abcdef"[2:])
print(a[-2:] if false else a[2])
# coalesce
let z = nil
print(z ?? "dflt", 0 ?? 5, false ?? 1, nil ?? nil ?? 7)
func side():
    print("evaluated")
    return 9
print(1 ?? side())
print(nil ?? side())
# destructuring
let [p, q, ...rest] = [1, 2, 3, 4, 5]
print(p, q, rest)
const [u, v] = [7, 8, 9]
print(u, v)
let {x, y: yy} = {x: 10, y: 20}
print(x, yy)
class Pt:
    let px = 1
    let py = 2
let {px, py} = Pt()
print(px, py)
func f():
    let [m, n2] = [1, 2]
    let [m2, n3] = [m + 1, n2 + 1]
    return m + n2 + m2 + n3
print(f())
try:
    let [e1, e2] = [1]
catch e:
    print(e.kind)
# new compound operators
let c = 2
c **= 5
print(c)
c &= 0b1100
c |= 3
c ^= 1
c <<= 2
c >>= 1
print(c)
